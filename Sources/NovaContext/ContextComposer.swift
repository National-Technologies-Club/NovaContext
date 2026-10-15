import Foundation

/// Builds a bounded initial request without retrieval, persistence or model invocation.
public enum ContextComposer {
    /// Mandatory instructions/question come first, then whole memories in supplied order,
    /// then a contiguous suffix of complete history turns. Nothing is truncated or summarized.
    /// Inputs preserve their original bytes. History must be supplied oldest to newest.
    /// Throws `requiredInputTooLarge` if mandatory content cannot fit; no partial request is returned.
    public static func compose(
        instructions: String, question: String, memories: ContextPayload,
        history: [ConversationTurn] = [], budget: CompositionBudget = .init(),
        tokenCounter: (any RequestTokenCounter)? = nil
    ) async throws -> ComposedContext {
        try Task.checkCancellation()
        try validate(instructions: instructions, question: question, history: history,
                     budget: budget, tokenCounter: tokenCounter)
        var selectedMemories: [Memory] = []
        var selectedHistory: [ConversationTurn] = []
        var memoryText = ""
        var input = try render(instructions: instructions, question: question, memoryText: "", history: [])
        guard var measurement = try await measure(input, budget: budget, tokenCounter: tokenCounter) else {
            throw NovaContextError.requiredInputTooLarge
        }

        for memory in memories.memories {
            try Task.checkCancellation()
            let candidate = selectedMemories + [memory]
            let text = try ContextRendering.render(candidate)
            let proposed = try render(instructions: instructions, question: question, memoryText: text, history: [])
            guard let fit = try await measure(proposed, budget: budget, tokenCounter: tokenCounter) else { continue }
            selectedMemories = candidate
            memoryText = text
            input = proposed
            measurement = fit
        }

        for turn in history.suffix(budget.maxHistoryTurns).reversed() {
            try Task.checkCancellation()
            let candidate = [turn] + selectedHistory
            let proposed = try render(instructions: instructions, question: question, memoryText: memoryText, history: candidate)
            guard let fit = try await measure(proposed, budget: budget, tokenCounter: tokenCounter) else { break }
            selectedHistory = candidate
            input = proposed
            measurement = fit
        }
        try Task.checkCancellation()
        let finalMemories = ContextPayload(
            memories: selectedMemories, text: memoryText, utf8Bytes: memoryText.utf8.count, tokenCount: nil,
            omittedCount: memories.omittedCount + (memories.memories.count - selectedMemories.count))
        return ComposedContext(input: input, memoryContext: finalMemories, history: selectedHistory,
            utf8Bytes: measurement.bytes, tokenCount: measurement.tokens,
            omittedHistoryTurnCount: history.count - selectedHistory.count)
    }

    private static func validate(instructions: String, question: String, history: [ConversationTurn],
                                 budget: CompositionBudget, tokenCounter: (any RequestTokenCounter)?) throws {
        guard instructions.utf8.count <= 8_192,
              validText(question, maxBytes: 1_024), history.count <= 32,
              history.allSatisfy({ validText($0.user, maxBytes: 4_096) && validText($0.assistant, maxBytes: 4_096) }) else {
            throw NovaContextError.invalidArgument("Instructions must fit 8,192 UTF-8 bytes; question must be nonblank and fit 1,024 bytes; history must contain at most 32 nonblank pairs of at most 4,096 bytes per field.")
        }
        guard (0...65_536).contains(budget.maxUTF8Bytes), (0...32).contains(budget.maxHistoryTurns),
              budget.maxTokens.map({ $0 >= 0 }) ?? true, budget.reservedTokens >= 0,
              budget.maxTokens.map({ budget.reservedTokens <= $0 }) ?? (budget.reservedTokens == 0) else {
            throw NovaContextError.invalidArgument("Composition limits must be 0...65,536 UTF-8 bytes, 0...32 history turns, and nonnegative tokens; reservation requires and cannot exceed a token cap.")
        }
        if budget.maxTokens != nil && tokenCounter == nil { throw NovaContextError.tokenCounterRequired }
    }

    private static func validText(_ text: String, maxBytes: Int) -> Bool {
        text.utf8.count <= maxBytes && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct Measurement {
        let bytes: Int
        let tokens: Int?
    }

    private static func measure(_ input: ComposedInput, budget: CompositionBudget,
                                tokenCounter: (any RequestTokenCounter)?) async throws -> Measurement? {
        try Task.checkCancellation()
        let bytes = input.instructions.utf8.count + input.prompt.utf8.count
        guard bytes <= budget.maxUTF8Bytes else { return nil }
        var tokens: Int?
        if let limit = budget.maxTokens, let tokenCounter {
            let count = try await tokenCounter.countTokens(in: input)
            try Task.checkCancellation()
            guard count >= 0 else { throw NovaContextError.invalidTokenCount }
            guard count <= limit - budget.reservedTokens else { return nil }
            tokens = count
        }
        return Measurement(bytes: bytes, tokens: tokens)
    }

    private static func render(instructions: String, question: String, memoryText: String,
                               history: [ConversationTurn]) throws -> ComposedInput {
        let reference = memoryText.isEmpty ? "No stored memories selected." : memoryText
        var prompt = "Reference context:\n" + reference
        if !history.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = try encoder.encode(history.map { HistoryRecord(user: $0.user, assistant: $0.assistant) })
            prompt += "\n\nRecent conversation (reference data):\n" + String(decoding: json, as: UTF8.self)
        }
        prompt += "\n\nQuestion:\n" + question
        return ComposedInput(instructions: instructions, prompt: prompt)
    }

    private struct HistoryRecord: Encodable {
        let user: String
        let assistant: String
    }
}
