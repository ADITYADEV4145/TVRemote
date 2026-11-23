/// Which layer understood an utterance.
public enum InterpreterLayer: String, Sendable {
    case grammar, contentSearch, languageModel, fallback
}

public struct InterpretationResult: Equatable, Sendable {
    public var transcript: String
    public var interpretation: VoiceInterpretation
    /// `nil` when nothing understood the utterance.
    public var layer: InterpreterLayer?
}

/// Runs the three layers cheapest first: grammar, explicit content search,
/// the on-device language model (when present), then a best-effort search.
public struct VoicePipeline: Sendable {
    public var grammar: GrammarInterpreter
    public var contentSearch: ContentSearchInterpreter
    public var languageModel: LanguageModelInterpreter?

    public init(
        grammar: GrammarInterpreter = .init(),
        contentSearch: ContentSearchInterpreter = .init(),
        languageModel: LanguageModelInterpreter? = nil
    ) {
        self.grammar = grammar
        self.contentSearch = contentSearch
        self.languageModel = languageModel
    }

    public func interpret(_ transcript: String, context: VoiceContext = .init()) async -> InterpretationResult {
        if let result = interpretOffline(transcript, context: context) { return result }
        if let languageModel, let answer = await languageModel.interpret(transcript, context: context), answer != .unrecognized {
            return InterpretationResult(transcript: transcript, interpretation: adapt(answer, context), layer: .languageModel)
        }
        if let answer = contentSearch.interpretFallback(transcript, context: context) {
            return InterpretationResult(transcript: transcript, interpretation: answer, layer: .fallback)
        }
        return InterpretationResult(transcript: transcript, interpretation: .unrecognized, layer: nil)
    }

    /// The deterministic layers only; `nil` when they do not understand.
    public func interpretOffline(_ transcript: String, context: VoiceContext = .init()) -> InterpretationResult? {
        if let answer = grammar.interpret(transcript, context: context) {
            return InterpretationResult(transcript: transcript, interpretation: answer, layer: .grammar)
        }
        if let answer = contentSearch.interpretExplicit(transcript, context: context) {
            return InterpretationResult(transcript: transcript, interpretation: answer, layer: .contentSearch)
        }
        return nil
    }

    private func adapt(_ answer: VoiceInterpretation, _ context: VoiceContext) -> VoiceInterpretation {
        if case let .command(.search(_, app?)) = answer, !context.supportsSearch {
            return .command(.launch(app))
        }
        return answer
    }
}
