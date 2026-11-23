/// Layer 1: a deterministic, offline parser for the core command set
/// ("volume up", "mute", "open Netflix", "channel 7", "go down three times").
public struct GrammarInterpreter: Sendable {
    public init() {}

    /// Returns `nil` when the utterance is outside the grammar, so the next layer can try.
    public func interpret(_ text: String, context: VoiceContext = .init()) -> VoiceInterpretation? {
        let all = TextNormalizer.words(text)
        if all == ["ok"] || all == ["okay"] { return .command(.key(.select)) }
        let words = TextNormalizer.stripFillers(all)
        guard !words.isEmpty else { return nil }
        let w = words.filter { $0 != "the" }
        guard !w.isEmpty else { return nil }

        if words[0] != "write", let typed = typing(words, original: text) { return .command(typed) }
        // "search for HDMI 2" is a search, left to the content-search layer.
        if searchVerbs.contains(w[0]), w.count > 1 {
            return navigation(w).map { .command($0) }
        }
        for rule in [captions, seek, volume, power, channel, input, playback, navigation] {
            if let command = rule(w) { return .command(command) }
        }
        if let typed = typing(words, original: text) { return .command(typed) }
        return launch(w, catalog: context.catalog)
    }

    // MARK: - Rules

    private func captions(_ w: [String]) -> VoiceCommand? {
        let words: Set = ["captions", "caption", "subtitles", "subtitle", "cc", "closed"]
        guard w.contains(where: words.contains), !searchVerbs.contains(w[0]) else { return nil }
        return .key(.captions)
    }

    private func seek(_ w: [String]) -> VoiceCommand? {
        guard let unitIndex = w.firstIndex(where: { ["second", "seconds", "secs", "sec", "minute", "minutes", "min", "mins"].contains($0) }) else {
            return nil
        }
        let isMinutes = w[unitIndex].hasPrefix("min")
        var amount: Int
        if unitIndex > 0, let n = Self.numberEnding(at: unitIndex, in: w) {
            amount = n
        } else if unitIndex > 0, ["a", "one"].contains(w[unitIndex - 1]) {
            amount = 1
        } else {
            return nil
        }
        if isMinutes { amount *= 60 }
        let backWords: Set = ["back", "backward", "backwards", "rewind", "previous"]
        let forwardWords: Set = ["forward", "ahead", "skip", "fast", "jump", "forwards"]
        if w.contains(where: backWords.contains) { return .seek(seconds: -amount) }
        if w.contains(where: forwardWords.contains) { return .seek(seconds: amount) }
        return nil
    }

    private func volume(_ w: [String]) -> VoiceCommand? {
        let volumeWords: Set = ["volume", "sound", "audio", "voliume", "valium"]
        let target: Set = ["tv", "television", "it", "sound", "audio", "volume", "this", "that"]
        let hasVolumeWord = w.contains(where: volumeWords.contains)

        // Mute and unmute.
        if w[0] == "unmute" || w[0] == "un" && w.dropFirst().first == "mute" { return .volume(.unmute) }
        if w[0] == "mute" && w.dropFirst().allSatisfy(target.contains) { return .volume(.mute) }
        if ["silence", "shh", "shush", "quiet", "hush"].contains(w[0]) && w.dropFirst().allSatisfy(target.contains) {
            return .volume(.mute)
        }
        if w == ["be", "quiet"] || w == ["go", "quiet"] { return .volume(.mute) }
        if hasVolumeWord {
            let rest = Set(w).subtracting(volumeWords).subtracting(["turn", "switch", "the", "back", "put", "kill", "cut", "is"])
            if rest == ["off"] || rest == ["kill"] || w.first == "kill" || w.first == "cut" && rest.isSubset(of: ["off"]) {
                return .volume(.mute)
            }
            if rest == ["on"] { return .volume(.unmute) }
        }

        // Relative changes.
        let upWords: Set = ["up", "louder", "raise", "increase", "higher", "boost", "crank", "lauder", "app"]
        let downWords: Set = ["down", "softer", "quieter", "lower", "decrease", "reduce", "quiet"]
        let verbsWithoutVolumeWord: Set = ["louder", "lauder", "softer", "quieter"]
        let isUp = w.contains(where: upWords.contains)
        let isDown = w.contains(where: downWords.contains)
        let turnIt = w.first == "turn" && (w.dropFirst().first == "it" || w.dropFirst().first.map(upWords.union(downWords).contains) == true)
        let pronounVerb = ["raise", "increase", "lower", "decrease", "reduce", "boost", "crank", "bring"].contains(w[0]) && w.dropFirst().first == "it"
        let relative = (hasVolumeWord || turnIt || pronounVerb || verbsWithoutVolumeWord.contains(w[0])
            || w.contains("louder") || w.contains("quieter") || w.contains("softer"))
        if relative && isUp != isDown {
            if w.contains("app") && !(w.first == "volume" && w.count <= 3) { return nil }
            let steps = Self.amount(in: w) ?? 1
            return .volume(isUp ? .up(steps) : .down(steps))
        }

        // Absolute level: "volume 20", "set the volume to 15", "volume at 30 percent".
        if hasVolumeWord, !isUp, !isDown,
           let i = w.indices.first(where: { NumberWords.parse(w[$0...]) != nil }),
           let n = NumberWords.parse(w[i...]) {
            let allowed: Set = ["set", "make", "put", "change", "turn", "volume", "sound", "to", "at", "percent", "level", "it"]
            let others = Array(w[..<i]) + Array(w[(i + n.count)...])
            if others.allSatisfy(allowed.contains) {
                return .volume(.set(min(max(n.value, 0), 100)))
            }
        }
        return nil
    }

    private func power(_ w: [String]) -> VoiceCommand? {
        let target: Set = ["tv", "television", "it", "screen", "everything", "display", "power", "set"]
        let verbs: Set = ["turn", "switch", "power", "shut", "put", "wake", "go"]
        if w == ["power"] || w == ["power", "button"] || w == ["toggle", "power"] || w == ["press", "power"] {
            return .power(.toggle)
        }
        if w.first == "wake" && w.dropFirst().allSatisfy({ target.contains($0) || $0 == "up" }) { return .power(.on) }
        if ["goodnight"].contains(w[0]) || w == ["good", "night"] || w == ["go", "to", "sleep"] || w == ["sleep"] {
            return .power(.off)
        }
        let rest = w.filter { !verbs.contains($0) && !target.contains($0) }
        let usesVerbOrTarget = w.contains(where: verbs.contains) || w.contains(where: target.contains)
        guard usesVerbOrTarget || w.count == 1 else { return nil }
        if rest == ["off"] || rest == ["down"] && w.first == "shut" || rest == ["down"] && w.first == "power" { return .power(.off) }
        if rest == ["on"] || rest == ["up"] && w.first == "power" { return .power(.on) }
        return nil
    }

    private func channel(_ w: [String]) -> VoiceCommand? {
        guard let i = w.firstIndex(where: { ["channel", "chanel", "channels", "station"].contains($0) }) else { return nil }
        let after = w[(i + 1)...]
        let before = w[..<i]
        if let n = NumberWords.channel(after) { return .channel(.number(n)) }
        if after.first.map({ ["up", "higher", "plus"].contains($0) }) == true || before.last == "next" { return .channel(.up) }
        if after.first.map({ ["down", "lower", "minus"].contains($0) }) == true { return .channel(.down) }
        if before.last.map({ ["previous", "last", "prior"].contains($0) }) == true || after.first == "back" || before.contains("back") && after.isEmpty {
            return .channel(.previous)
        }
        return nil
    }

    private func input(_ w: [String]) -> VoiceCommand? {
        if let i = w.firstIndex(where: { $0 == "hdmi" || $0.hasPrefix("hdmi") && Int($0.dropFirst(4)) != nil }) {
            if let n = Int(w[i].dropFirst(4)) { return .input(.hdmi(n)) }
            if let n = NumberWords.parse(w[(i + 1)...], allowHomophones: true) { return .input(.hdmi(n.value)) }
            if let port = w[(i + 1)...].first, port.count == 1, let n = Int(port) { return .input(.hdmi(n)) }
            return .input(.hdmi(1))
        }
        if w.contains("antenna") || w.contains("tuner") || w.contains("aerial") || w == ["cable"] || w.contains("over") && w.contains("air") {
            return .input(.tuner)
        }
        let inputWords: Set = ["input", "inputs", "source", "sources"]
        let fillers: Set = ["change", "switch", "next", "cycle", "toggle", "press", "button", "go", "to", "a", "different"]
        if w.contains(where: inputWords.contains), w.allSatisfy({ inputWords.contains($0) || fillers.contains($0) }) {
            return .input(.next)
        }
        return nil
    }

    private func playback(_ w: [String]) -> VoiceCommand? {
        let objects: Set = ["it", "this", "that", "show", "movie", "video", "tv", "episode", "film", "playback", "song", "music", "game", "stream"]
        func only(_ verbs: Set<String>) -> Bool {
            verbs.contains(w[0]) && w.dropFirst().allSatisfy(objects.contains)
        }
        if w == ["play", "pause"] || w == ["play", "slash", "pause"] || w == ["toggle", "play"] { return .key(.playPause) }
        if only(["pause", "paws", "pours", "hold", "freeze"]) || w == ["hold", "on"] || w == ["wait"] || w == ["stop", "for", "a", "second"] {
            return .key(.pause)
        }
        if only(["play", "resume", "continue", "unpause", "start"]) && (w.count > 1 || w[0] != "start") || w == ["keep", "playing"] || w == ["keep", "going"] || w == ["start", "playing"] {
            return .key(.play)
        }
        if only(["stop"]) { return .key(.stop) }
        if only(["rewind"]) || w == ["go", "backwards"] { return .key(.rewind) }
        if w == ["fast", "forward"] || w == ["fastforward"] || w == ["forward"] || w == ["ff"] || w == ["fast", "forward", "it"] {
            return .key(.fastForward)
        }
        if (w.contains("next") || w == ["skip", "episode"] || w == ["skip", "song"] || w == ["skip", "track"]),
           w.allSatisfy({ ["next", "skip", "go", "to", "play", "episode", "track", "song", "chapter", "video", "one"].contains($0) }) {
            return .key(.next)
        }
        if w.contains(where: { ["previous", "last"].contains($0) }),
           w.allSatisfy({ ["previous", "last", "go", "to", "play", "episode", "track", "song", "chapter", "video", "back"].contains($0) }) {
            return .key(.previous)
        }
        if w == ["replay"] || w == ["instant", "replay"] || w == ["start", "over"] || w == ["restart"] || w == ["from", "beginning"]
            || w == ["play", "from", "beginning"] || w == ["start", "from", "beginning"] || w == ["play", "again"] {
            return .key(.replay)
        }
        if w == ["skip"] || w == ["skip", "ahead"] || w == ["skip", "forward"] || w == ["jump", "ahead"] {
            return .seek(seconds: 30)
        }
        if w == ["skip", "back"] || w == ["jump", "back"] || w == ["skip", "backward"] {
            return .seek(seconds: -10)
        }
        return nil
    }

    private func navigation(_ w: [String]) -> VoiceCommand? {
        // Single-purpose buttons.
        let tables: [(VoiceKey, [[String]])] = [
            (.home, [["home"], ["go", "home"], ["home", "screen"], ["home", "page"], ["go", "to", "home"], ["go", "to", "home", "screen"],
                     ["main", "menu"], ["take", "me", "home"], ["press", "home"], ["home", "button"], ["go", "to", "main", "menu"]]),
            (.back, [["back"], ["go", "back"], ["return"], ["previous", "screen"], ["press", "back"], ["back", "button"], ["exit"],
                     ["go", "back", "one"], ["take", "me", "back"], ["get", "out"], ["close", "this"], ["close", "it"], ["go", "back", "a", "screen"], ["back", "up"]]),
            (.select, [["select"], ["enter"], ["click"], ["choose"], ["pick"], ["confirm"], ["press", "ok"], ["press", "okay"], ["hit", "ok"], ["hit", "okay"], ["click", "ok"], ["click", "okay"], ["tap", "ok"], ["tap", "okay"],
                       ["press", "select"], ["press", "enter"], ["select", "it"], ["select", "this"], ["select", "that"],
                       ["choose", "this"], ["choose", "that"], ["click", "it"], ["click", "that"], ["ok", "button"], ["okay", "button"], ["open", "it"], ["open", "this"], ["open", "that"], ["pick", "that", "one"], ["pick", "this", "one"], ["that", "one"]]),
            (.menu, [["menu"], ["options"], ["option"], ["star"], ["star", "button"], ["open", "menu"], ["show", "options"], ["more", "options"], ["show", "menu"], ["show", "the", "menu"]]),
            (.info, [["info"], ["information"], ["details"], ["more", "info"], ["show", "info"], ["guide"], ["show", "details"]]),
            (.settings, [["settings"], ["open", "settings"], ["go", "to", "settings"], ["setting"], ["tv", "settings"]]),
            (.search, [["search"], ["open", "search"], ["go", "to", "search"], ["search", "screen"]]),
        ]
        for (key, phrases) in tables where phrases.contains(w) { return .key(key) }

        // Directions, optionally repeated: "down", "go left twice", "move right 3 times", "down down down".
        let directions: [String: VoiceKey] = ["up": .up, "down": .down, "left": .left, "right": .right, "write": .right, "rite": .right, "op": .up]
        let verbs: Set = ["go", "move", "scroll", "press", "hit", "navigate", "swipe", "arrow", "key", "button", "one", "tap", "click", "a", "bit", "more"]
        let dirWords = w.filter { directions[$0] != nil }
        guard let firstDir = dirWords.first, let key = directions[firstDir] else { return nil }
        if dirWords.allSatisfy({ directions[$0] == key }), dirWords.count > 1,
           w.allSatisfy({ directions[$0] == key }) {
            return .key(key, times: dirWords.count)
        }
        guard dirWords.count == 1 else { return nil }
        var rest = w.filter { directions[$0] == nil && !verbs.contains($0) }
        var times = 1
        if !rest.isEmpty {
            if rest == ["twice"] { times = 2 }
            else if rest == ["thrice"] { times = 3 }
            else if rest == ["once"] { times = 1 }
            else if rest.last == "times" || rest.last == "time", let n = NumberWords.parse(rest.dropLast()[...], allowHomophones: true), n.count == rest.count - 1 {
                times = n.value
            } else if ["a", "couple", "few", "of", "times"].contains(rest[0]) {
                rest.removeAll { ["a", "of", "times"].contains($0) }
                if rest == ["couple"] { times = 2 } else if rest == ["few"] { times = 3 } else { return nil }
            } else if let n = NumberWords.parse(rest[...]), n.count == rest.count {
                times = n.value
            } else {
                return nil
            }
        }
        guard (1...20).contains(times) else { return nil }
        return .key(key, times: times)
    }

    private func typing(_ words: [String], original: String) -> VoiceCommand? {
        let verbs: [[String]] = [["type", "in"], ["enter", "text"], ["type"], ["write"], ["spell"]]
        guard let verb = verbs.first(where: { words.count > $0.count && Array(words.prefix($0.count)) == $0 }) else { return nil }
        // Keep the user's spelling and case: take the text after the verb in the original transcript.
        let tokens = original.split(separator: " ", omittingEmptySubsequences: true)
        var index = 0
        var matched = 0
        while index < tokens.count, matched < verb.count {
            if TextNormalizer.words(String(tokens[index])) == [verb[matched]] { matched += 1 }
            index += 1
        }
        let text = tokens[index...].joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return text.isEmpty ? nil : .type(text)
    }

    private func launch(_ w: [String], catalog: AppCatalog) -> VoiceInterpretation? {
        let verbs: [[String]] = [
            ["open", "up"], ["open"], ["launch"], ["start"], ["run"], ["load"], ["go", "to"], ["goto"], ["switch", "to"], ["change", "to"],
            ["bring", "up"], ["pull", "up"], ["fire", "up"], ["boot", "up"], ["jump", "to"], ["take", "me", "to"], ["show", "me"],
            ["put", "on"], ["turn", "on"], ["watch"], ["play"], ["i", "want"], ["get"], ["show"],
        ]
        let verb = verbs.first { w.count > $0.count && Array(w.prefix($0.count)) == $0 }
        var rest = Array(w.dropFirst(verb?.count ?? 0))
        if let last = rest.last, rest.count > 1, ["app", "application", "channel"].contains(last) {
            rest.removeLast()
        }
        guard !rest.isEmpty else { return nil }

        switch catalog.match(rest.joined(separator: " ")) {
        case let .exact(app), let .fuzzy(app):
            return .command(.launch(app.id))
        case let .ambiguous(apps):
            let names = apps.map(\.name)
            let question = "Did you mean " + names.dropLast().joined(separator: ", ") + " or " + names.last! + "?"
            return .clarify(question: question, options: apps.map { .launch($0.id) })
        case .none:
            return nil
        }
    }

    // MARK: - Helpers

    let searchVerbs: Set<String> = ["search", "find", "look"]

    /// A number ending right before `index`, e.g. the "30" in "skip 30 seconds".
    static func numberEnding(at index: Int, in w: [String]) -> Int? {
        for start in stride(from: max(0, index - 4), to: index, by: 1) {
            if let n = NumberWords.parse(w[start..<index]), n.count == index - start { return n.value }
        }
        return nil
    }

    /// The size of a relative change: "by 5", "3 steps", "a bit", "a lot".
    static func amount(in w: [String]) -> Int? {
        for i in w.indices {
            if let n = NumberWords.parse(w[i...]), (1...50).contains(n.value) { return n.value }
        }
        let joined = " " + w.joined(separator: " ") + " "
        if [" a lot ", " lot ", " way ", " much ", " a ton "].contains(where: joined.contains) { return 5 }
        if [" bit ", " little ", " slightly ", " touch ", " notch ", " tad "].contains(where: joined.contains) { return 2 }
        if joined.contains(" couple ") { return 2 }
        if joined.contains(" few ") { return 3 }
        return nil
    }
}
