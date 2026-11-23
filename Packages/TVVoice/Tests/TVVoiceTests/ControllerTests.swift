import XCTest
@testable import TVVoice

final class RecordingExecutor: VoiceCommandExecutor, @unchecked Sendable {
    var commands: [VoiceCommand] = []
    var events: [String] = []
    func execute(_ command: VoiceCommand) async throws {
        events.append("execute")
        commands.append(command)
    }
    func beginVoiceCapture() async { events.append("begin") }
    func endVoiceCapture() async { events.append("end") }
}

final class RecordingMissLog: MissLog {
    var misses: [String] = []
    func record(_ transcript: String) { misses.append(transcript) }
}

@MainActor
final class ControllerTests: XCTestCase {
    func testHoldToTalkRunsCommandAndRestoresSoundFirst() async {
        let executor = RecordingExecutor()
        let transcriber = ScriptedSpeechTranscriber(transcript: "open netflix")
        let controller = VoiceController(transcriber: transcriber, executor: executor)
        await controller.startListening()
        XCTAssertTrue(controller.isListening)
        await controller.stopListening()
        XCTAssertEqual(executor.commands, [.launch("netflix")])
        XCTAssertEqual(executor.events, ["begin", "end", "execute"])
        XCTAssertEqual(controller.state, .confirmed("Opening Netflix"))
        XCTAssertNotNil(controller.lastLatency)
    }

    func testUnrecognizedIsLoggedNotRun() async {
        let executor = RecordingExecutor()
        let log = RecordingMissLog()
        let controller = VoiceController(transcriber: ScriptedSpeechTranscriber(), executor: executor, missLog: log)
        await controller.handle(text: "what's the weather")
        XCTAssertEqual(executor.commands, [])
        XCTAssertEqual(log.misses, ["what's the weather"])
        XCTAssertEqual(controller.state, .notUnderstood(transcript: "what's the weather"))
    }

    func testAmbiguousAppAsksOnce() async {
        let executor = RecordingExecutor()
        let catalog = AppCatalog(entries: [AppEntry(id: "a", name: "Pluto TV"), AppEntry(id: "b", name: "Pluto Kids")])
        let controller = VoiceController(transcriber: ScriptedSpeechTranscriber(), executor: executor,
                                         context: { VoiceContext(catalog: catalog) })
        await controller.handle(text: "open pluto")
        guard case let .clarifying(_, options) = controller.state else { return XCTFail("\(controller.state)") }
        await controller.choose(options[0])
        XCTAssertEqual(executor.commands, [options[0]])
    }
}
