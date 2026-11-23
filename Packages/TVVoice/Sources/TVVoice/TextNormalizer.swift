import Foundation

enum TextNormalizer {
    /// Lowercased words with punctuation removed. "Disney+" becomes
    /// ["disney", "plus"]; "7.1", "7-1" and "x3" stay one word.
    static func words(_ text: String) -> [String] {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "+", with: " plus ")
        s = s.replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "%", with: " percent ")
        var out = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber || c == " " {
                out.append(c)
            } else if c == "'" {
                continue
            } else if c == ".", i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber {
                out.append(c)
            } else if c == "-", i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber {
                out.append(c)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").map(String.init)
    }

    static let leadingFillers: [[String]] = [
        ["hey", "tv"], ["hey", "remote"], ["ok", "tv"], ["okay", "tv"],
        ["can", "you", "please"], ["could", "you", "please"], ["would", "you", "please"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["i", "want", "to"], ["i", "wanna"], ["i", "would", "like", "to"], ["id", "like", "to"],
        ["i", "need", "to"], ["lets"], ["please"], ["just"], ["um"], ["uh"], ["hey"], ["ok"], ["okay"],
        ["so"], ["now"], ["go", "ahead", "and"], ["quickly"],
    ]

    static let trailingFillers: [[String]] = [
        ["please"], ["for", "me"], ["right", "now"], ["now"], ["thanks"], ["thank", "you"], ["ok"], ["okay"],
    ]

    static let okWords: Set<[String]> = [["ok"], ["okay"]]
    static let pressVerbs: Set = ["press", "hit", "click", "tap"]

    static func stripFillers(_ words: [String]) -> [String] {
        var w = words[...]
        var changed = true
        while changed, !w.isEmpty {
            changed = false
            for f in leadingFillers where w.count > f.count && Array(w.prefix(f.count)) == f
                && !(okWords.contains(f) && w.dropFirst(f.count).first == "button") {
                w = w.dropFirst(f.count)
                changed = true
                break
            }
        }
        changed = true
        while changed, !w.isEmpty {
            changed = false
            for f in trailingFillers where w.count > f.count && Array(w.suffix(f.count)) == f
                && !(okWords.contains(f) && pressVerbs.contains(w[w.endIndex - f.count - 1])) {
                w = w.dropLast(f.count)
                changed = true
                break
            }
        }
        return Array(w)
    }
}

enum NumberWords {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    /// Homophones speech recognition writes for digits after "channel", "hdmi" and the like.
    static let homophones: [String: Int] = ["to": 2, "too": 2, "for": 4, "fore": 4, "won": 1, "ate": 8, "tree": 3]

    /// Parses a whole number at the start of `words`. Returns the value and how many words it used.
    static func parse(_ words: ArraySlice<String>, allowHomophones: Bool = false) -> (value: Int, count: Int)? {
        guard let first = words.first else { return nil }
        if let n = Int(first) { return (n, 1) }
        if first.hasPrefix("x"), let n = Int(first.dropFirst()) { return (n, 1) }
        if allowHomophones, let n = homophones[first] { return (n, 1) }

        enum Last { case start, unit, ten, hundred, and }
        var last = Last.start
        var value = 0
        var used = 0
        for w in words {
            if let u = units[w] {
                switch last {
                case .start, .hundred, .and: value += u
                case .ten where u < 10: value += u
                default: return used > 0 ? (value, used) : nil
                }
                last = .unit
            } else if let t = tens[w] {
                guard [.start, .hundred, .and].contains(last) else { break }
                value += t
                last = .ten
            } else if w == "hundred", last == .unit, value < 10 {
                value *= 100
                last = .hundred
            } else if w == "and", last == .hundred {
                last = .and
            } else if let n = Int(w), last == .ten, n < 10 {
                value += n
                last = .unit
            } else {
                break
            }
            used += 1
        }
        if last == .and { used -= 1 }
        return used > 0 ? (value, used) : nil
    }

    /// Parses a channel number such as "7", "7.1", "seven point one" or "7 dash 1".
    static func channel(_ words: ArraySlice<String>) -> String? {
        guard let first = words.first else { return nil }
        if first.contains(where: { $0 == "." || $0 == "-" }) {
            let parts = first.split(whereSeparator: { $0 == "." || $0 == "-" })
            return parts.count == 2 && parts.allSatisfy({ Int($0) != nil }) ? parts.joined(separator: ".") : nil
        }
        guard let major = parse(words, allowHomophones: true) else { return nil }
        let rest = words.dropFirst(major.count)
        if let sep = rest.first, ["point", "dot", "dash"].contains(sep),
           let minor = parse(rest.dropFirst(), allowHomophones: true) {
            return "\(major.value).\(minor.value)"
        }
        return String(major.value)
    }
}
