import Foundation

/// Counts a complete nonempty context block with the caller's model-specific tokenizer.
/// Called synchronously outside storage locks, only when `maxTokens` is set and the
/// candidate fits the byte limit. Return a nonnegative count; thrown errors propagate.
/// No callback is made for an omitted/empty block, which contributes zero context tokens.
public protocol TokenCounter: Sendable {
    func countTokens(in text: String) throws -> Int
}

/// Limits apply to the returned context block, not the entire model prompt.
/// Valid ranges are 0...128 memories, 0...65,536 UTF-8 bytes, and optional nonnegative
/// tokens. A token limit requires a counter. Zero in any limit selects no memories.
/// Validation occurs when context is requested, rather than in this initializer.
public struct ContextBudget: Sendable, Equatable {
    public var maxMemories: Int
    public var maxUTF8Bytes: Int
    public var maxTokens: Int?

    public init(maxMemories: Int = 12, maxUTF8Bytes: Int = 8_192, maxTokens: Int? = nil) {
        self.maxMemories = maxMemories
        self.maxUTF8Bytes = maxUTF8Bytes
        self.maxTokens = maxTokens
    }
}

/// An owned snapshot of selected memories and its complete rendered context.
/// `utf8Bytes` includes the header, JSON metadata, and escaped content. `tokenCount`
/// is nil without a token limit, otherwise the supplied counter's accepted count
/// (zero for an empty block). `omittedCount` includes every unselected scoped record.
public struct ContextPayload: Sendable, Equatable {
    public let memories: [Memory]
    public let text: String
    public let utf8Bytes: Int
    public let tokenCount: Int?
    public let omittedCount: Int
}
