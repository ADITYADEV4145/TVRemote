#if canImport(FoundationModels)
import FoundationModels
import TVVoice

/// Layer 2 backed by Apple's on-device Foundation Models (iOS 26 and later).
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsBackend: LanguageModelBackend {
    public init() {}

    /// `false` on devices without Apple Intelligence, or while the model downloads.
    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }
}
#endif
