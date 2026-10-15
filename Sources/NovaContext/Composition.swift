/// A complete user/assistant pair supplied by the host, ordered oldest to newest.
/// Composition does not capture or persist conversation history.
public struct ConversationTurn: Sendable, Equatable {
    public let user: String
    public let assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

/// Send these exact fields to the model adapter. Instructions stay separate from data.
public struct ComposedInput: Sendable, Equatable {
    public let instructions: String
    public let prompt: String

    public init(instructions: String, prompt: String) {
        self.instructions = instructions
        self.prompt = prompt
    }
}

/// Counts the complete two-field input, only for byte-fitting candidates with a token cap.
/// Return a deterministic nonnegative count; thrown errors propagate. Include provider framing, tools
/// or schemas here if the adapter adds them. No storage lock is held while awaiting it.
public protocol RequestTokenCounter: Sendable {
    func countTokens(in input: ComposedInput) async throws -> Int
}

/// Limits all strings managed by the composer, rather than just a memory block.
/// Valid ranges: 0...65,536 UTF-8 bytes, 0...32 history turns, nonnegative tokens.
/// A token cap requires a request counter. Reservation requires a cap and cannot exceed it.
/// Validation happens on composition. Zero allowances can reject mandatory content.
public struct CompositionBudget: Sendable, Equatable {
    public var maxUTF8Bytes: Int
    public var maxHistoryTurns: Int
    public var maxTokens: Int?
    public var reservedTokens: Int

    public init(maxUTF8Bytes: Int = 16_384, maxHistoryTurns: Int = 4,
                maxTokens: Int? = nil, reservedTokens: Int = 0) {
        self.maxUTF8Bytes = maxUTF8Bytes
        self.maxHistoryTurns = maxHistoryTurns
        self.maxTokens = maxTokens
        self.reservedTokens = reservedTokens
    }
}

/// The final request and its selected reference data, with whole-record omission counts.
/// Bytes are the UTF-8 sum of instructions and prompt, including rendering overhead.
/// `tokenCount` covers the whole input under the supplied counter, or is nil without a cap.
/// `memoryContext` is rerendered for the final subset, preserves upstream scoped omissions,
/// and has nil `tokenCount`: the composer does not count that block independently.
public struct ComposedContext: Sendable, Equatable {
    public let input: ComposedInput
    public let memoryContext: ContextPayload
    public let history: [ConversationTurn]
    public let utf8Bytes: Int
    public let tokenCount: Int?
    public let omittedHistoryTurnCount: Int
}
