import Foundation
import FoundationModels
import NovaContext

@MainActor protocol LocalResponder {
    var availability: ModelAvailability { get }
    func respond(to input: ComposedInput) async throws -> String
}

enum ModelAvailability: Equatable {
    case available
    case unavailable(String)
}

enum DemoError: Error, Equatable, LocalizedError {
    case unavailable, contextWindow, invalidQuestion, generationInProgress
    var errorDescription: String? {
        switch self {
        case .unavailable: "The on-device model is unavailable. Memory actions still work."
        case .contextWindow: "The model context window is full. Shorten the question or remove memories, then try again."
        case .invalidQuestion: "Enter a question of 1–1,024 UTF-8 bytes."
        case .generationInProgress: "A response is already in progress."
        }
    }
}

@MainActor protocol ResponseSession {
    func respond(to prompt: String) async throws -> String
}

@MainActor final class AppleResponder: LocalResponder {
    private let checkAvailability: @MainActor () -> ModelAvailability
    private let makeSession: @MainActor (String) -> any ResponseSession
    private var isResponding = false
    var availability: ModelAvailability { checkAvailability() }
    init(availability: @escaping @MainActor () -> ModelAvailability = AppleResponder.systemAvailability,
         makeSession: @escaping @MainActor (String) -> any ResponseSession = { AppleSession(instructions: $0) }) {
        self.checkAvailability = availability
        self.makeSession = makeSession
    }
    func respond(to input: ComposedInput) async throws -> String {
        guard !isResponding else { throw DemoError.generationInProgress }
        guard availability == .available else { throw DemoError.unavailable }
        try Task.checkCancellation()
        isResponding = true
        defer { isResponding = false }
        // A new session per question prevents a hidden, ever-growing transcript.
        let session = makeSession(input.instructions)
        do {
            let answer = try await session.respond(to: input.prompt)
            try Task.checkCancellation()
            return answer
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw DemoError.contextWindow
        } catch {
            // Xcode 26 remains supported; recognize the renamed error with newer SDKs.
            #if compiler(>=6.4)
            if #available(iOS 27, *), case LanguageModelError.contextSizeExceeded = error {
                throw DemoError.contextWindow
            }
            #endif
            throw error
        }
    }

    static func systemAvailability() -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("This device cannot run the on-device model. Memory actions still work.")
            case .appleIntelligenceNotEnabled: return .unavailable("Enable Apple Intelligence in Settings to ask the model.")
            case .modelNotReady: return .unavailable("The on-device model is not ready yet. Try again after it finishes downloading.")
            @unknown default: return .unavailable("The on-device model is unavailable. Memory actions still work.")
            }
        }
    }
}

@MainActor private final class AppleSession: ResponseSession {
    private let session: LanguageModelSession
    init(instructions: String) {
        session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }
    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 256)).content
    }
}

/// An explicit UI preview mode; it never calls a model or pretends to infer an answer.
@MainActor final class PreviewResponder: LocalResponder {
    var availability: ModelAvailability { .available }
    func respond(to input: ComposedInput) async throws -> String {
        try Task.checkCancellation()
        return "Model-free preview. No language model was called. Inspect the exact request above."
    }
}
