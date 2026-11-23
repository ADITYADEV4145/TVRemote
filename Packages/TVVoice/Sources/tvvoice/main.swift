import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TVVoice

// Developer tool: parse utterances, score the golden set, or drive a (simulated) Roku.
//   tvvoice parse "open netflix"
//   tvvoice eval [path/to/core-commands.tsv]
//   tvvoice roku http://127.0.0.1:8060 "volume up three"

let args = Array(CommandLine.arguments.dropFirst())
let defaultGoldenSet = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("GoldenSet/core-commands.tsv")

func usage() -> Never {
    print("usage: tvvoice parse <text> | eval [golden.tsv] | roku <base-url> <text>...")
    exit(2)
}

switch args.first {
case "parse":
    let text = args.dropFirst().joined(separator: " ")
    let result = await VoicePipeline().interpret(text)
    print("\(result.interpretation.canonical)\t[\(result.layer?.rawValue ?? "none")]")
    if case let .command(c) = result.interpretation { print(c.confirmation()) }
case "eval":
    let url = args.count > 1 ? URL(fileURLWithPath: args[1]) : defaultGoldenSet
    let set = try GoldenSet.load(url)
    let report = await set.evaluate(pipeline: VoicePipeline())
    print(report.summary)
    for miss in report.misses { print("MISS [\(miss.category)] \"\(miss.utterance)\" expected \(miss.expected) got \(miss.actual)") }
    exit(report.passesGate ? 0 : 1)
case "roku":
    guard args.count >= 3, let base = URL(string: args[1]) else { usage() }
    let executor = RokuECPExecutor(base: base)
    for text in args.dropFirst(2) {
        let result = await VoicePipeline().interpret(text)
        guard case let .command(command) = result.interpretation else {
            print("\"\(text)\" -> \(result.interpretation.canonical) (not sent)")
            continue
        }
        do {
            let start = ContinuousClock.now
            try await executor.execute(command)
            print("\"\(text)\" -> \(command.canonical): \(command.confirmation()) (\(ContinuousClock.now - start))")
        } catch {
            print("\"\(text)\" -> \(command.canonical): failed: \(error)")
        }
    }
default:
    usage()
}
