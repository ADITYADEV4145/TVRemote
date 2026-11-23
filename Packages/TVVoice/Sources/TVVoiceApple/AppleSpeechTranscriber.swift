#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech
import TVVoice

/// On-device speech recognition with Apple's Speech framework. Audio never leaves
/// the phone: recognition fails rather than falling back to Apple's servers.
public final class AppleSpeechTranscriber: SpeechTranscriber {
    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init?(locale: Locale = .current) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        self.recognizer = recognizer
    }

    /// Asks for speech recognition and microphone access. Call before the first capture.
    public static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return true
        #endif
    }

    public func start(vocabulary: [String]) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw SpeechTranscriberError.notAuthorized }
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechTranscriberError.onDeviceRecognitionUnavailable }
        cancel()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechTranscriberError.audioUnavailable
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.contextualStrings = vocabulary
        request.addsPunctuation = false
        self.request = request

        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechTranscriberError.audioUnavailable
        }

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                continuation.yield(TranscriptUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                if result.isFinal { continuation.finish() }
            } else if error != nil {
                // Recognition ends with an error when no speech was heard; the last partial stands.
                continuation.finish()
            }
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stopAudio() }
        }
        return stream
    }

    public func finish() async {
        stopAudio()
        request?.endAudio()
    }

    public func cancel() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
#endif
