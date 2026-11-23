public struct TranscriptUpdate: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public enum SpeechTranscriberError: Error, Equatable, Sendable {
    case notAuthorized
    case onDeviceRecognitionUnavailable
    case audioUnavailable
}

/// Speech-to-text that runs on the phone. `TVVoiceApple` provides the Apple Speech
/// implementation; `ScriptedSpeechTranscriber` replays text for tests and previews.
public protocol SpeechTranscriber: AnyObject {
    /// Starts capturing. `vocabulary` biases recognition toward app names and commands.
    func start(vocabulary: [String]) async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    /// The user stopped speaking: deliver the final transcript and end the stream.
    func finish() async
    func cancel()
}

/// Replays a scripted transcript: partial results on `start`, the final one on `finish`.
public final class ScriptedSpeechTranscriber: SpeechTranscriber {
    public var transcript: String
    public private(set) var lastVocabulary: [String] = []
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?

    public init(transcript: String = "") {
        self.transcript = transcript
    }

    public func start(vocabulary: [String]) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        lastVocabulary = vocabulary
        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        self.continuation = continuation
        let words = transcript.split(separator: " ")
        for count in words.indices.dropLast() {
            continuation.yield(TranscriptUpdate(text: words[...count].joined(separator: " "), isFinal: false))
        }
        return stream
    }

    public func finish() async {
        continuation?.yield(TranscriptUpdate(text: transcript, isFinal: true))
        continuation?.finish()
        continuation = nil
    }

    public func cancel() {
        continuation?.finish()
        continuation = nil
    }
}
