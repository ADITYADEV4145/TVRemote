import Foundation

/// A platform-neutral app identifier such as `netflix`. Drivers map it to their
/// own app IDs; apps reported by the TV can use the TV's own ID instead.
public struct AppID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

public struct AppEntry: Hashable, Sendable {
    public var id: AppID
    public var name: String
    /// Extra spoken forms, including common speech-recognition misspellings.
    public var aliases: [String]

    public init(id: AppID, name: String, aliases: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
    }

    var spokenForms: [String] { [name] + aliases }
}

/// The apps voice commands can open, matched tolerantly against what was heard.
public struct AppCatalog: Sendable {
    public enum Match: Equatable, Sendable {
        case exact(AppEntry)
        case fuzzy(AppEntry)
        case ambiguous([AppEntry])
        case none

        public var entry: AppEntry? {
            switch self {
            case let .exact(e), let .fuzzy(e): return e
            case .ambiguous, .none: return nil
            }
        }
    }

    public private(set) var entries: [AppEntry]
    private var keys: [(key: String, index: Int)]

    public init(entries: [AppEntry]) {
        self.entries = []
        self.keys = []
        for entry in entries { add(entry) }
    }

    /// Adds the apps installed on the current TV. An installed app whose name
    /// matches a standard entry keeps the standard ID; others are added as new.
    public func adding(installed apps: [AppEntry]) -> AppCatalog {
        var copy = self
        for app in apps {
            if case let .exact(existing) = copy.match(app.name) {
                if let i = copy.entries.firstIndex(of: existing) {
                    copy.entries[i].aliases.append(contentsOf: app.aliases)
                    copy.rebuildKeys()
                }
            } else {
                copy.add(app)
            }
        }
        return copy
    }

    public func entry(for id: AppID) -> AppEntry? {
        entries.first { $0.id == id }
    }

    public func match(_ phrase: String) -> Match {
        let key = Self.key(phrase)
        guard !key.isEmpty else { return .none }
        if let hit = keys.first(where: { $0.key == key }) {
            return .exact(entries[hit.index])
        }
        guard key.count >= 4 else { return .none }

        // "Pluto" when the TV has "Pluto TV" and "Pluto Kids".
        let prefixed = Set(keys.filter { $0.key.hasPrefix(key) }.map(\.index)).sorted()
        if prefixed.count == 1 { return .fuzzy(entries[prefixed[0]]) }
        if prefixed.count > 1 { return .ambiguous(prefixed.map { entries[$0] }) }

        var best: [Int: Double] = [:]
        for (candidate, index) in keys where candidate.count >= 4 {
            let score = Self.similarity(key, candidate)
            if score > (best[index] ?? 0) { best[index] = score }
        }
        let ranked = best.filter { $0.value >= 0.75 }.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return .none }
        let close = ranked.filter { top.value - $0.value < 0.05 }
        if close.count > 1 {
            return .ambiguous(close.map { entries[$0.key] })
        }
        return .fuzzy(entries[top.key])
    }

    /// Names to bias speech recognition toward.
    public var vocabulary: [String] { entries.map(\.name) }

    private mutating func add(_ entry: AppEntry) {
        entries.append(entry)
        let index = entries.count - 1
        for form in entry.spokenForms {
            let k = Self.key(form)
            if !k.isEmpty { keys.append((k, index)) }
        }
    }

    private mutating func rebuildKeys() {
        let all = entries
        entries = []
        keys = []
        for e in all { add(e) }
    }

    /// Lowercased letters and digits only, with "+" spoken as "plus".
    static func key(_ text: String) -> String {
        let spoken = TextNormalizer.words(text).joined()
        return String(spoken.filter { $0.isLetter || $0.isNumber })
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let distance = levenshtein(Array(a), Array(b))
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

extension AppCatalog {
    /// Common streaming apps across TV platforms.
    public static let standard = AppCatalog(entries: [
        AppEntry(id: "netflix", name: "Netflix", aliases: ["net flix", "netflicks", "netflex", "nexflix"]),
        AppEntry(id: "youtube", name: "YouTube", aliases: ["you tube", "u tube", "utube", "youtub"]),
        AppEntry(id: "youtube-tv", name: "YouTube TV", aliases: ["you tube tv"]),
        AppEntry(id: "youtube-kids", name: "YouTube Kids", aliases: ["you tube kids"]),
        AppEntry(id: "prime-video", name: "Prime Video", aliases: ["amazon prime", "amazon prime video", "prime", "amazon", "amazon video"]),
        AppEntry(id: "disney-plus", name: "Disney+", aliases: ["disney", "disney plus", "disneyplus", "disney+"]),
        AppEntry(id: "hulu", name: "Hulu", aliases: ["who lou", "hoolu", "hulu plus"]),
        AppEntry(id: "max", name: "Max", aliases: ["hbo max", "hbo", "h b o", "hbo go"]),
        AppEntry(id: "apple-tv", name: "Apple TV", aliases: ["apple tv plus", "apple tv+", "apple"]),
        AppEntry(id: "peacock", name: "Peacock", aliases: ["pea cock", "peacock tv"]),
        AppEntry(id: "paramount-plus", name: "Paramount+", aliases: ["paramount", "paramount plus"]),
        AppEntry(id: "spotify", name: "Spotify", aliases: ["spot ify", "spotty fi"]),
        AppEntry(id: "apple-music", name: "Apple Music"),
        AppEntry(id: "pandora", name: "Pandora"),
        AppEntry(id: "plex", name: "Plex", aliases: ["plecs"]),
        AppEntry(id: "tubi", name: "Tubi", aliases: ["tubby", "tube e", "tubee", "tuby"]),
        AppEntry(id: "pluto-tv", name: "Pluto TV", aliases: ["pluto"]),
        AppEntry(id: "sling", name: "Sling TV", aliases: ["sling"]),
        AppEntry(id: "crunchyroll", name: "Crunchyroll", aliases: ["crunchy roll"]),
        AppEntry(id: "twitch", name: "Twitch"),
        AppEntry(id: "espn", name: "ESPN", aliases: ["e s p n", "espn plus", "espn+"]),
        AppEntry(id: "fubo", name: "Fubo", aliases: ["fubo tv", "foo bo"]),
        AppEntry(id: "philo", name: "Philo", aliases: ["filo"]),
        AppEntry(id: "discovery-plus", name: "Discovery+", aliases: ["discovery", "discovery plus"]),
        AppEntry(id: "starz", name: "Starz", aliases: ["stars"]),
        AppEntry(id: "amc-plus", name: "AMC+", aliases: ["amc", "amc plus", "a m c"]),
        AppEntry(id: "britbox", name: "BritBox", aliases: ["brit box"]),
        AppEntry(id: "mubi", name: "MUBI", aliases: ["moobie"]),
        AppEntry(id: "pbs", name: "PBS", aliases: ["p b s"]),
        AppEntry(id: "pbs-kids", name: "PBS Kids", aliases: ["p b s kids"]),
        AppEntry(id: "fandango-at-home", name: "Fandango at Home", aliases: ["vudu", "voodoo"]),
        AppEntry(id: "roku-channel", name: "The Roku Channel", aliases: ["roku channel"]),
        AppEntry(id: "live-tv", name: "Live TV", aliases: ["live tv guide"]),
        AppEntry(id: "iheartradio", name: "iHeartRadio", aliases: ["i heart radio", "iheart"]),
        AppEntry(id: "kodi", name: "Kodi"),
    ])
}
