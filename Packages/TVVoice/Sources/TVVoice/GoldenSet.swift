import Foundation

/// Labeled utterances scored on every build. The gate is the plan's promise 3:
/// at least 95% correct on the `core` category.
public struct GoldenSet: Sendable {
    public struct Case: Sendable {
        public var category: String
        public var utterance: String
        public var expected: String
    }

    public struct Miss: Sendable {
        public var category: String
        public var utterance: String
        public var expected: String
        public var actual: String
    }

    public struct Report: Sendable {
        public var totals: [String: (passed: Int, total: Int)]
        public var misses: [Miss]
        public var p95ParseTime: Duration
        public static let coreGate = 0.95

        public func accuracy(_ category: String) -> Double {
            guard let t = totals[category], t.total > 0 else { return 0 }
            return Double(t.passed) / Double(t.total)
        }

        public var passesGate: Bool { accuracy("core") >= Self.coreGate }

        public var summary: String {
            totals.keys.sorted().map { key in
                let t = totals[key]!
                return String(format: "%@: %d/%d (%.1f%%)", key, t.passed, t.total, accuracy(key) * 100)
            }.joined(separator: "\n") + "\np95 interpret time: \(p95ParseTime)\ncore gate (\(Int(Self.coreGate * 100))%): \(passesGate ? "pass" : "FAIL")"
        }
    }

    public var cases: [Case]

    /// Tab-separated `category<TAB>utterance<TAB>expected`; `#` starts a comment.
    public static func load(_ url: URL) throws -> GoldenSet {
        let text = try String(contentsOf: url, encoding: .utf8)
        let cases = text.split(whereSeparator: \.isNewline).compactMap { line -> Case? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 else { return nil }
            return Case(category: parts[0], utterance: parts[1], expected: parts[2])
        }
        return GoldenSet(cases: cases)
    }

    public func evaluate(pipeline: VoicePipeline, context: VoiceContext = .init()) async -> Report {
        var totals: [String: (passed: Int, total: Int)] = [:]
        var misses: [Miss] = []
        var times: [Duration] = []
        for c in cases {
            let start = ContinuousClock.now
            let result = await pipeline.interpret(c.utterance, context: context)
            times.append(ContinuousClock.now - start)
            let actual = result.interpretation.canonical
            var t = totals[c.category] ?? (0, 0)
            t.total += 1
            if actual == c.expected { t.passed += 1 } else {
                misses.append(Miss(category: c.category, utterance: c.utterance, expected: c.expected, actual: actual))
            }
            totals[c.category] = t
        }
        times.sort()
        let p95 = times.isEmpty ? .zero : times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        return Report(totals: totals, misses: misses, p95ParseTime: p95)
    }
}
