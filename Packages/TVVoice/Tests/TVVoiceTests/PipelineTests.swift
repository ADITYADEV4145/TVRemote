import XCTest
@testable import TVVoice

final class StubModel: LanguageModelBackend, @unchecked Sendable {
    var reply: String
    var delay: Duration = .zero
    private(set) var calls = 0
    init(_ reply: String) { self.reply = reply }
    func respond(instructions: String, prompt: String) async throws -> String {
        calls += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return reply
    }
}

final class PipelineTests: XCTestCase {
    func testGrammarRunsBeforeTheModel() async {
        let model = StubModel(#"{"action":"mute"}"#)
        let pipeline = VoicePipeline(languageModel: LanguageModelInterpreter(backend: model))
        let result = await pipeline.interpret("volume up")
        XCTAssertEqual(result.interpretation.canonical, "volume:up:1")
        XCTAssertEqual(result.layer, .grammar)
        XCTAssertEqual(model.calls, 0)
    }

    func testModelHandlesLoosePhrasing() async {
        let model = StubModel(#"{"action":"volume","direction":"down","steps":2}"#)
        let pipeline = VoicePipeline(languageModel: LanguageModelInterpreter(backend: model))
        let result = await pipeline.interpret("it's way too loud in here")
        XCTAssertEqual(result.interpretation.canonical, "volume:down:2")
        XCTAssertEqual(result.layer, .languageModel)
    }

    func testModelClarifiesInsteadOfGuessing() async {
        let model = StubModel(#"{"action":"clarify","question":"Which app?","options":[{"action":"launch","app":"netflix"},{"action":"launch","app":"hulu"}]}"#)
        let pipeline = VoicePipeline(languageModel: LanguageModelInterpreter(backend: model))
        let result = await pipeline.interpret("open my show app")
        XCTAssertEqual(result.interpretation.canonical, "clarify:launch:netflix|launch:hulu")
    }

    func testInvalidModelOutputFallsBack() async {
        let model = StubModel("Sure! I'll turn it down.")
        let pipeline = VoicePipeline(languageModel: LanguageModelInterpreter(backend: model))
        let result = await pipeline.interpret("put on something funny")
        XCTAssertEqual(result.interpretation.canonical, "search:comedy")
        XCTAssertEqual(result.layer, .fallback)
    }

    func testSlowModelTimesOut() async {
        let model = StubModel(#"{"action":"mute"}"#)
        model.delay = .seconds(5)
        let pipeline = VoicePipeline(languageModel: LanguageModelInterpreter(backend: model, timeout: .milliseconds(100)))
        let start = ContinuousClock.now
        _ = await pipeline.interpret("make it less noisy")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testModelCannotLaunchUnknownApps() async {
        let model = StubModel(#"{"action":"launch","app":"not-an-app"}"#)
        let pipeline = VoicePipeline(languageModel: LanguageModelInterpreter(backend: model))
        let result = await pipeline.interpret("start the thing")
        XCTAssertNotEqual(result.interpretation.canonical, "launch:not-an-app")
    }
}

final class GoldenSetTests: XCTestCase {
    func testCoreAccuracyGate() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GoldenSet/core-commands.tsv")
        let set = try GoldenSet.load(url)
        XCTAssertGreaterThanOrEqual(set.cases.filter { $0.category == "core" }.count, 500)
        let report = await set.evaluate(pipeline: VoicePipeline())
        print(report.summary)
        XCTAssertGreaterThanOrEqual(report.accuracy("core"), GoldenSet.Report.coreGate, report.misses.map { "\($0.utterance) -> \($0.actual)" }.joined(separator: "\n"))
        XCTAssertEqual(report.accuracy("negative"), 1)
    }
}
