/// Words to bias on-device recognition toward: app names first, then commands.
public enum VoiceVocabulary {
    public static let commands: [String] = [
        "volume up", "volume down", "mute", "unmute", "channel up", "channel down", "go back", "home",
        "select", "pause", "play", "rewind", "fast forward", "captions", "subtitles", "HDMI 1", "HDMI 2",
        "HDMI 3", "input", "turn off the TV", "turn on the TV", "skip 30 seconds", "next episode", "open", "search for",
    ]

    /// Apple's recognizers work best with a short list; this stays under `limit` entries.
    public static func contextualStrings(catalog: AppCatalog, limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for phrase in catalog.vocabulary + commands where seen.insert(phrase.lowercased()).inserted {
            out.append(phrase)
            if out.count == limit { break }
        }
        return out
    }
}
