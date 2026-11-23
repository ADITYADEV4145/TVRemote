import Foundation
import Observation

/// Runs voice commands on the connected TV. The app implements this on top of
/// the connection manager, mapping `VoiceCommand` to the driver's key codes.
public protocol VoiceCommandExecutor: AnyObject {
    func execute(_ command: VoiceCommand) async throws
    /// Called when capture starts, so the TV can be muted or ducked while the user speaks.
    func beginVoiceCapture() async
    /// Called when capture ends, before the command runs, to restore the TV's sound.
    func endVoiceCapture() async
}

extension VoiceCommandExecutor {
    public func beginVoiceCapture() async {}
    public func endVoiceCapture() async {}
}

/// Opt-in, text-only log of utterances nothing understood, used to grow the grammar.
public protocol MissLog: AnyObject {
    func record(_ transcript: String)
}

/// Hold-to-talk voice control: capture, understand, run, confirm.
@MainActor
@Observable
public final class VoiceController {
    public enum State: Equatable, Sendable {
        case idle
        case listening(transcript: String)
        case understanding(transcript: String)
        case executing(VoiceCommand)
        /// The one-line confirmation, e.g. "Opening Netflix".
        case confirmed(String)
        case clarifying(question: String, options: [VoiceCommand])
        case notUnderstood(transcript: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Time from the end of speech to the TV command completing, for the last command.
    public private(set) var lastLatency: Duration?
    public private(set) var lastResult: InterpretationResult?

    @ObservationIgnored private let transcriber: any SpeechTranscriber
    @ObservationIgnored private let executor: any VoiceCommandExecutor
    @ObservationIgnored private let pipeline: VoicePipeline
    @ObservationIgnored private let context: @MainActor () -> VoiceContext
    @ObservationIgnored private let muteWhileListening: Bool
    @ObservationIgnored private weak var missLog: (any MissLog)?
    @ObservationIgnored private var listenTask: Task<String, Never>?
    @ObservationIgnored private var captureActive = false

    public init(
        transcriber: any SpeechTranscriber,
        executor: any VoiceCommandExecutor,
        pipeline: VoicePipeline = .init(),
        muteWhileListening: Bool = true,
        missLog: (any MissLog)? = nil,
        context: @escaping @MainActor () -> VoiceContext = { VoiceContext() }
    ) {
        self.transcriber = transcriber
        self.executor = executor
        self.pipeline = pipeline
        self.muteWhileListening = muteWhileListening
        self.missLog = missLog
        self.context = context
    }

    public var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    /// Hold began.
    public func startListening() async {
        guard !isListening else { return }
        state = .listening(transcript: "")
        if muteWhileListening {
            captureActive = true
            await executor.beginVoiceCapture()
        }
        let stream: AsyncThrowingStream<TranscriptUpdate, Error>
        do {
            stream = try await transcriber.start(vocabulary: VoiceVocabulary.contextualStrings(catalog: context().catalog))
        } catch {
            await restoreSound()
            state = .failed(Self.message(for: error, otherwise: "Voice isn't available right now."))
            return
        }
        listenTask = Task { [weak self] in
            var latest = ""
            do {
                for try await update in stream {
                    latest = update.text
                    if let self, self.isListening { self.state = .listening(transcript: latest) }
                    if update.isFinal { break }
                }
            } catch {}
            return latest
        }
    }

    /// Hold released: the end of speech. Understands and runs the command.
    public func stopListening() async {
        guard isListening, let listenTask else { return }
        let endOfSpeech = ContinuousClock.now
        await transcriber.finish()
        let transcript = await listenTask.value
        self.listenTask = nil
        let restore = Task { await restoreSound() }
        await run(transcript, since: endOfSpeech, beforeExecuting: restore)
    }

    public func cancel() async {
        transcriber.cancel()
        listenTask?.cancel()
        listenTask = nil
        await restoreSound()
        state = .idle
    }

    /// Runs typed or Siri-provided text through the same path, with no audio.
    public func handle(text: String) async {
        await run(text, since: .now, beforeExecuting: nil)
    }

    /// The user picked an answer to a clarifying question.
    public func choose(_ option: VoiceCommand) async {
        await execute(option, since: .now)
    }

    private func run(_ transcript: String, since start: ContinuousClock.Instant, beforeExecuting restore: Task<Void, Never>?) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            await restore?.value
            state = .notUnderstood(transcript: "")
            return
        }
        state = .understanding(transcript: text)
        let result = await pipeline.interpret(text, context: context())
        lastResult = result
        await restore?.value
        switch result.interpretation {
        case let .command(command):
            await execute(command, since: start)
        case let .clarify(question, options):
            state = .clarifying(question: question, options: options)
        case .unrecognized:
            missLog?.record(text)
            state = .notUnderstood(transcript: text)
        }
    }

    private func execute(_ command: VoiceCommand, since start: ContinuousClock.Instant) async {
        state = .executing(command)
        do {
            try await executor.execute(command)
            lastLatency = ContinuousClock.now - start
            state = .confirmed(command.confirmation(catalog: context().catalog))
        } catch {
            state = .failed(Self.message(for: error, otherwise: "Couldn't reach the TV."))
        }
    }

    private func restoreSound() async {
        guard captureActive else { return }
        captureActive = false
        await executor.endVoiceCapture()
    }

    static func message(for error: Error, otherwise fallback: String) -> String {
        switch error as? SpeechTranscriberError {
        case .notAuthorized: return "Allow microphone and speech recognition in Settings to use voice."
        case .onDeviceRecognitionUnavailable: return "On-device speech isn't available for this language yet."
        case .audioUnavailable: return "The microphone is busy."
        case nil: return fallback
        }
    }
}
