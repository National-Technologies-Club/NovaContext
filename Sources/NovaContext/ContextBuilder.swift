import Foundation

enum ContextBuilder {
    static func validate(_ budget: ContextBudget, tokenCounter: (any TokenCounter)?) throws {
        guard (0...128).contains(budget.maxMemories),
              (0...65_536).contains(budget.maxUTF8Bytes),
              budget.maxTokens.map({ $0 >= 0 }) ?? true else {
            throw NovaContextError.invalidArgument("Context limits must be 0...128 memories, 0...65,536 UTF-8 bytes, and nonnegative tokens.")
        }
        if budget.maxTokens != nil && tokenCounter == nil {
            throw NovaContextError.tokenCounterRequired
        }
    }

    static func build(memories: [Memory], budget: ContextBudget,
                      tokenCounter: (any TokenCounter)?) throws -> ContextPayload {
        try Task.checkCancellation()
        return try pack(orderedMemories: memories.sorted(by: MemoryOrdering.precedes),
                        totalScopeCount: memories.count, budget: budget, tokenCounter: tokenCounter)
    }

    /// Preserves caller ranking while accounting for every unselected scoped record.
    static func pack(orderedMemories: [Memory], totalScopeCount: Int, budget: ContextBudget,
                     tokenCounter: (any TokenCounter)?) throws -> ContextPayload {
        try Task.checkCancellation()
        try validate(budget, tokenCounter: tokenCounter)
        var selected: [Memory] = []
        var text = ""
        var bytes = 0
        var tokens: Int? = budget.maxTokens == nil ? nil : 0

        if budget.maxMemories > 0 && budget.maxUTF8Bytes > 0 && budget.maxTokens != 0 {
            for memory in orderedMemories {
                try Task.checkCancellation()
                if selected.count == budget.maxMemories { break }
                let candidate = selected + [memory]
                let candidateText = try ContextRendering.render(candidate)
                let candidateBytes = candidateText.utf8.count
                guard candidateBytes <= budget.maxUTF8Bytes else { continue }

                var candidateTokens: Int?
                if let limit = budget.maxTokens, let tokenCounter {
                    let count = try tokenCounter.countTokens(in: candidateText)
                    try Task.checkCancellation()
                    guard count >= 0 else { throw NovaContextError.invalidTokenCount }
                    guard count <= limit else { continue }
                    candidateTokens = count
                }
                selected = candidate
                text = candidateText
                bytes = candidateBytes
                tokens = candidateTokens
            }
        }
        try Task.checkCancellation()
        return ContextPayload(memories: selected, text: text, utf8Bytes: bytes,
                              tokenCount: tokens, omittedCount: totalScopeCount - selected.count)
    }
}
