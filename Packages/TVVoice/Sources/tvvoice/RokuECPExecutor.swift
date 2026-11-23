import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TVVoice

/// A minimal Roku ECP sender for exercising voice commands against a real or
/// simulated Roku. Dev tool only: the app uses the driver package.
final class RokuECPExecutor: VoiceCommandExecutor {
    struct Unsupported: Error, CustomStringConvertible { let description: String }

    let base: URL
    init(base: URL) { self.base = base }

    static let appIDs: [AppID: String] = [
        "netflix": "12", "youtube": "837", "prime-video": "13", "hulu": "2285", "disney-plus": "291097",
        "max": "61322", "apple-tv": "551012", "peacock": "593099", "paramount-plus": "31440", "spotify": "22297",
        "plex": "13535", "tubi": "41468", "pluto-tv": "74519", "roku-channel": "151908", "youtube-tv": "195316",
    ]

    func execute(_ command: VoiceCommand) async throws {
        switch command {
        case let .key(key, times):
            for _ in 0..<times { try await post("keypress/\(try Self.rokuKey(key))") }
        case let .volume(action):
            switch action {
            case let .up(n): for _ in 0..<n { try await post("keypress/VolumeUp") }
            case let .down(n): for _ in 0..<n { try await post("keypress/VolumeDown") }
            case .mute, .unmute: throw Unsupported(description: "Roku ECP has only a mute toggle, so it cannot set mute on or off")
            case .set: throw Unsupported(description: "Roku has no absolute volume")
            }
        case let .power(action):
            try await post("keypress/" + ["on": "PowerOn", "off": "PowerOff", "toggle": "Power"][action.rawValue]!)
        case let .channel(action):
            switch action {
            case let .number(n): try await post("launch/tvinput.dtv?ch=\(n)")
            case .up: try await post("keypress/ChannelUp")
            case .down: try await post("keypress/ChannelDown")
            case .previous: throw Unsupported(description: "Roku ECP has no previous-channel key")
            }
        case let .launch(app):
            guard let id = Self.appIDs[app] else { throw Unsupported(description: "no Roku ID for \(app)") }
            try await post("launch/\(id)")
        case let .search(query, app):
            var path = "search/browse?keyword=\(Self.escape(query))&launch=true"
            if let app, let id = Self.appIDs[app] { path += "&provider-id=\(id)" }
            try await post(path)
        case let .seek(seconds):
            let key = seconds < 0 ? "InstantReplay" : "Fwd"
            try await post("keypress/\(key)")
        case let .input(source):
            switch source {
            case let .hdmi(n): try await post("keypress/InputHDMI\(n)")
            case .tuner: try await post("keypress/InputTuner")
            case .next: throw Unsupported(description: "Roku has no next-input key")
            }
        case let .type(text):
            for scalar in text.unicodeScalars { try await post("keypress/Lit_\(Self.escape(String(scalar)))") }
        }
    }

    static func rokuKey(_ key: VoiceKey) throws -> String {
        switch key {
        case .home: return "Home"
        case .back: return "Back"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .select: return "Select"
        case .menu, .info: return "Info"
        case .search: return "Search"
        case .play, .pause, .playPause: return "Play"
        case .rewind: return "Rev"
        case .fastForward: return "Fwd"
        case .replay: return "InstantReplay"
        case .settings, .stop, .next, .previous, .captions: throw Unsupported(description: "Roku ECP has no \(key) key")
        }
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func post(_ path: String) async throws {
        guard let url = URL(string: path, relativeTo: base) else { throw Unsupported(description: "bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Unsupported(description: "HTTP \(http.statusCode) for \(path)")
        }
    }
}
