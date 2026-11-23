import Foundation

/// A text-in, text-out on-device language model. The app supplies one backed by
/// Apple's Foundation Models framework (see `TVVoiceApple`); tests use stubs.
public protocol LanguageModelBackend: Sendable {
    func respond(instructions: String, prompt: String) async throws -> String
}

/// Layer 2: maps loose phrasing ("turn it down a bit", "put on something funny")
/// to a structured command by asking an on-device model for one JSON object.
public struct LanguageModelInterpreter: Sendable {
    public var backend: any LanguageModelBackend
    /// After this the model's answer is dropped and the next layer runs.
    public var timeout: Duration

    public init(backend: any LanguageModelBackend, timeout: Duration = .milliseconds(1200)) {
        self.backend = backend
        self.timeout = timeout
    }

    public func interpret(_ text: String, context: VoiceContext = .init()) async -> VoiceInterpretation? {
        let instructions = Self.instructions(catalog: context.catalog)
        let prompt = "Request: \"\(text.replacingOccurrences(of: "\"", with: "'"))\""
        let backend = self.backend
        let timeout = self.timeout
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await backend.respond(instructions: instructions, prompt: prompt) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply else { return nil }
        return Self.decode(reply, catalog: context.catalog)
    }

    public static func instructions(catalog: AppCatalog) -> String {
        let keys = VoiceKey.allCases.map(\.rawValue).joined(separator: ", ")
        let apps = catalog.entries.map { "\($0.id.rawValue) (\($0.name))" }.joined(separator: ", ")
        return """
        You turn one spoken TV remote request into exactly one JSON object and reply with JSON only.
        Allowed objects:
        {"action":"key","key":"<key>","times":1}  keys: \(keys)
        {"action":"volume","direction":"up"|"down","steps":1-20}
        {"action":"volume","level":0-100}
        {"action":"mute"} {"action":"unmute"}
        {"action":"power","state":"on"|"off"|"toggle"}
        {"action":"channel","number":"7"} or {"action":"channel","direction":"up"|"down"|"previous"}
        {"action":"launch","app":"<app id>"}
        {"action":"search","query":"<title, person or genre>","app":"<optional app id>"}
        {"action":"seek","seconds":<negative to go back>}
        {"action":"input","hdmi":1-4} or {"action":"input","source":"tuner"|"next"}
        {"action":"type","text":"<text>"}
        {"action":"clarify","question":"<one short question>","options":[<up to 4 of the objects above>]}
        {"action":"none"}
        App ids: \(apps)
        "A bit" means 2 volume steps, "a lot" means 5. Use search for shows, movies and genres ("something funny" is query "comedy").
        If the request is unclear, use clarify. If it is not a TV request, use none.
        """
    }

    /// Validates the model's reply; anything outside the allowed shapes is rejected.
    public static func decode(_ reply: String, catalog: AppCatalog) -> VoiceInterpretation? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return decode(object: json, catalog: catalog, allowClarify: true)
    }

    static func decode(object json: [String: Any], catalog: AppCatalog, allowClarify: Bool) -> VoiceInterpretation? {
        guard let action = json["action"] as? String else { return nil }

        func int(_ key: String) -> Int? {
            if let n = json[key] as? Int { return n }
            if let d = json[key] as? Double { return d.isFinite && abs(d) < 1_000_000 ? Int(d) : nil }
            if let s = json[key] as? String { return Int(s) }
            return nil
        }
        func string(_ key: String) -> String? {
            (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        func app(_ key: String) -> AppID? {
            guard let raw = string(key) else { return nil }
            if catalog.entry(for: AppID(raw)) != nil { return AppID(raw) }
            return catalog.match(raw).entry?.id
        }

        switch action {
        case "key":
            guard let raw = string("key"), let key = VoiceKey(rawValue: raw) else { return nil }
            guard let times = json["times"] == nil ? 1 : int("times"), (1...20).contains(times) else { return nil }
            return .command(.key(key, times: times))
        case "volume":
            if let level = int("level") {
                guard (0...100).contains(level) else { return nil }
                return .command(.volume(.set(level)))
            }
            guard let steps = json["steps"] == nil ? 1 : int("steps"), (1...20).contains(steps) else { return nil }
            switch string("direction") {
            case "up": return .command(.volume(.up(steps)))
            case "down": return .command(.volume(.down(steps)))
            default: return nil
            }
        case "mute": return .command(.volume(.mute))
        case "unmute": return .command(.volume(.unmute))
        case "power":
            guard let state = string("state").flatMap(PowerAction.init(rawValue:)) else { return nil }
            return .command(.power(state))
        case "channel":
            if let number = string("number") ?? int("number").map(String.init),
               number.split(separator: ".").allSatisfy({ Int($0) != nil }) {
                return .command(.channel(.number(number)))
            }
            switch string("direction") {
            case "up": return .command(.channel(.up))
            case "down": return .command(.channel(.down))
            case "previous": return .command(.channel(.previous))
            default: return nil
            }
        case "launch":
            guard let id = app("app") else { return nil }
            return .command(.launch(id))
        case "search":
            guard let query = string("query") else { return nil }
            return .command(.search(query: query.lowercased(), app: app("app")))
        case "seek":
            guard let seconds = int("seconds"), seconds != 0, (-3600...3600).contains(seconds) else { return nil }
            return .command(.seek(seconds: seconds))
        case "input":
            if let n = int("hdmi"), (1...8).contains(n) { return .command(.input(.hdmi(n))) }
            switch string("source") {
            case "tuner": return .command(.input(.tuner))
            case "next": return .command(.input(.next))
            default: return nil
            }
        case "type":
            guard let text = string("text") else { return nil }
            return .command(.type(text))
        case "clarify":
            guard allowClarify, let question = string("question") else { return nil }
            let options = (json["options"] as? [[String: Any]] ?? []).prefix(4).compactMap { option -> VoiceCommand? in
                if case let .command(command) = decode(object: option, catalog: catalog, allowClarify: false) { return command }
                return nil
            }
            return .clarify(question: question, options: Array(options))
        case "none":
            return .unrecognized
        default:
            return nil
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
