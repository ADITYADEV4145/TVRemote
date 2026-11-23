/// Layer 3: turns "find Severance" or "play The Office on Netflix" into a search
/// handed to the TV's own search.
public struct ContentSearchInterpreter: Sendable {
    public init() {}

    static let explicitVerbs: [[String]] = [
        ["search", "for"], ["search"], ["find", "me"], ["find"], ["look", "for"], ["look", "up"], ["lookup"],
    ]
    static let playVerbs: [[String]] = [
        ["play"], ["watch"], ["put", "on"], ["show", "me"], ["show"], ["i", "want", "to", "watch"], ["start", "watching"],
        ["continue", "watching"], ["resume"], ["stream"], ["queue", "up"], ["pull", "up"],
    ]
    /// Openers of a loose request ("put on something funny") better left to the language model.
    static let vagueOpeners: Set = ["something", "anything", "some", "a", "an", "whatever", "random", "stuff"]
    static let genres: [String: String] = [
        "funny": "comedy", "hilarious": "comedy", "scary": "horror", "spooky": "horror", "romantic": "romance",
        "exciting": "action", "animated": "animation", "for kids": "kids", "for the kids": "kids", "sad": "drama",
    ]

    /// Explicit searches only ("find X", "search for X", "play X"); vague requests return `nil`.
    public func interpretExplicit(_ text: String, context: VoiceContext = .init()) -> VoiceInterpretation? {
        let words = TextNormalizer.stripFillers(TextNormalizer.words(text))
        if let verb = Self.explicitVerbs.first(where: { Self.hasPrefix(words, $0) }) {
            return search(Array(words.dropFirst(verb.count)), context: context, allowVague: true)
        }
        if let verb = Self.playVerbs.first(where: { Self.hasPrefix(words, $0) }) {
            return search(Array(words.dropFirst(verb.count)), context: context, allowVague: false)
        }
        return nil
    }

    /// Best-effort fallback when no other layer understood: vague requests become a genre search.
    public func interpretFallback(_ text: String, context: VoiceContext = .init()) -> VoiceInterpretation? {
        let words = TextNormalizer.stripFillers(TextNormalizer.words(text))
        guard let verb = (Self.explicitVerbs + Self.playVerbs).first(where: { Self.hasPrefix(words, $0) }) else { return nil }
        return search(Array(words.dropFirst(verb.count)), context: context, allowVague: true)
    }

    private func search(_ words: [String], context: VoiceContext, allowVague: Bool) -> VoiceInterpretation? {
        var q = words
        var app: AppID?
        // "... on Netflix", "... in Hulu", "... using Prime Video"
        for split in q.indices.reversed() where ["on", "in", "using", "with", "from"].contains(q[split]) && split > 0 {
            var name = Array(q[(split + 1)...])
            if let last = name.last, name.count > 1, ["app", "application", "channel"].contains(last) { name.removeLast() }
            if let entry = context.catalog.match(name.joined(separator: " ")).entry {
                app = entry.id
                q = Array(q[..<split])
                break
            }
        }
        // "search YouTube for cat videos"
        if app == nil, let k = q.firstIndex(of: "for"), k > 0, let entry = context.catalog.match(q[..<k].joined(separator: " ")).entry {
            app = entry.id
            q = Array(q[(k + 1)...])
        }
        // Drop connective words but keep titles that start with them ("Movie 43", "Of Mice and Men").
        while q.first == "for" { q.removeFirst() }
        if q.starts(with: ["episodes", "of"]) { q.removeFirst(2) }
        // "movie Dune" and "show called Severance" name a title; "Show Dogs" and "Movie 43" are titles.
        var namedTitle = false
        if q.count > 2, ["show", "movie", "film", "series"].contains(q[0]), ["called", "named"].contains(q[1]) {
            q.removeFirst(2)
            namedTitle = true
        } else if q.count > 1, ["movie", "film"].contains(q[0]), !(q.count == 2 && Int(q[1]) != nil) {
            q.removeFirst()
            namedTitle = true
        }
        guard !q.isEmpty else { return nil }
        if !namedTitle, Self.vagueOpeners.contains(q[0]) {
            guard allowVague else { return nil }
            let phrase = q.joined(separator: " ")
            let kinds: Set = ["movie", "movies", "film", "films", "show", "shows", "series"]
            if let genre = Self.genres.first(where: { phrase.contains($0.key) })?.value {
                q = [genre]
            } else if let genre = Set(Self.genres.values).first(where: { q.contains($0) }),
                      q.allSatisfy({ $0 == genre || Self.vagueOpeners.contains($0) || kinds.contains($0) }) {
                q = [genre]
            } else {
                q.removeAll { Self.vagueOpeners.contains($0) || ["to", "watch", "good", "new", "on"].contains($0) }
                if q.isEmpty { return nil }
            }
        }
        let query = q.joined(separator: " ")
        if !context.supportsSearch, let app {
            return .command(.launch(app))
        }
        return .command(.search(query: query, app: app))
    }

    static func hasPrefix(_ words: [String], _ prefix: [String]) -> Bool {
        words.count > prefix.count && Array(words.prefix(prefix.count)) == prefix
    }
}
