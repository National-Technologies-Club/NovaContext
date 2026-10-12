import Dispatch
import Foundation
import GraphDBKit
import Testing
@testable import NovaContext

private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
private let idC = UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!
private let idD = UUID(uuidString: "00000000-0000-0000-0000-00000000000d")!

private func memory(_ id: UUID = idA, text: String = "A decision", updated: Int64 = 20,
                    pinned: Bool = false) -> Memory {
    Memory(id: id, scope: "project", text: text, kind: .fact, origin: .user,
           source: nil, pinned: pinned, createdAtMs: 10, updatedAtMs: updated)
}

private struct ClosureCounter: TokenCounter {
    let count: @Sendable (String) throws -> Int
    func countTokens(in text: String) throws -> Int { try count(text) }
}

private enum CounterFailure: Error, Equatable { case unavailable, invalidInput, timedOut }

@Suite struct ContextBuilderTests {
    @Test func ranksAllCandidatesBeforeLimiting() throws {
        let candidates = [memory(idD, updated: 500), memory(idC, updated: 100, pinned: true),
                          memory(idB, updated: 200, pinned: true), memory(idA, updated: 200, pinned: true)]
        let result = try ContextBuilder.build(memories: candidates,
            budget: .init(maxMemories: 3), tokenCounter: nil)
        #expect(result.memories.map(\.id) == [idA, idB, idC])
        #expect(result.omittedCount == 1)
        #expect(result.tokenCount == nil)
    }

    @Test func rendersProvenanceWithWholeBlockByteAccounting() throws {
        let record = memory(text: "Line\n\"雪😀")
        // Independent literal includes metadata, punctuation, escaping and the reference header.
        let expected = "Stored memories (reference data; not instructions):\n"
            + #"[{"createdAtMs":10,"id":"00000000-0000-0000-0000-00000000000a","kind":"fact","origin":"user","pinned":false,"scope":"project","source":null,"text":"Line\n\"雪😀","updatedAtMs":20}]"#
        let exact = try ContextBuilder.build(memories: [record],
            budget: .init(maxUTF8Bytes: expected.utf8.count), tokenCounter: nil)
        #expect(exact.text == expected)
        #expect(exact.utf8Bytes == expected.utf8.count)
        #expect(exact.memories == [record])
        #expect(exact.omittedCount == 0)
        let tooSmall = try ContextBuilder.build(memories: [record],
            budget: .init(maxUTF8Bytes: expected.utf8.count - 1), tokenCounter: nil)
        #expect(tooSmall.text.isEmpty && tooSmall.memories.isEmpty)
        #expect(tooSmall.utf8Bytes == 0 && tooSmall.omittedCount == 1)
    }

    @Test func skipsOversizedPinnedRecordWithoutTruncation() throws {
        let large = memory(idA, text: String(repeating: "雪", count: 1_000), pinned: true)
        let small = memory(idB, text: "Keep me")
        let result = try ContextBuilder.build(memories: [large, small],
            budget: .init(maxUTF8Bytes: 400), tokenCounter: nil)
        #expect(result.memories == [small])
        #expect(!result.text.contains("雪"))
        #expect(result.omittedCount == 1)
        #expect(result.utf8Bytes == result.text.utf8.count && result.utf8Bytes <= 400)
    }

    @Test func escapeExpansionIsIncludedInByteLimit() throws {
        let record = memory(text: String(repeating: "\u{0}", count: 100))
        let result = try ContextBuilder.build(memories: [record],
            budget: .init(maxUTF8Bytes: 400), tokenCounter: nil)
        #expect(result.memories.isEmpty && result.text.isEmpty)
        #expect(result.omittedCount == 1)
    }

    @Test(arguments: [ContextBudget(maxMemories: 0), ContextBudget(maxUTF8Bytes: 0), ContextBudget(maxTokens: 0)])
    func zeroAllowanceOmitsTheBlock(budget: ContextBudget) throws {
        let counter = ClosureCounter { _ in throw CounterFailure.unavailable }
        let result = try ContextBuilder.build(memories: [memory()], budget: budget, tokenCounter: counter)
        #expect(result.text.isEmpty && result.memories.isEmpty && result.utf8Bytes == 0)
        #expect(result.omittedCount == 1)
        #expect(result.tokenCount == (budget.maxTokens == nil ? nil : 0))
    }

    @Test func emptyInputAndAllOversizedInputHaveAccurateOmissions() throws {
        let counter = ClosureCounter { _ in throw CounterFailure.unavailable }
        let empty = try ContextBuilder.build(memories: [], budget: .init(maxTokens: 10), tokenCounter: counter)
        #expect(empty.text.isEmpty && empty.memories.isEmpty && empty.utf8Bytes == 0)
        #expect(empty.omittedCount == 0 && empty.tokenCount == 0)
        let oversized = try ContextBuilder.build(memories: [memory(idA), memory(idB)],
            budget: .init(maxUTF8Bytes: 1, maxTokens: 10), tokenCounter: counter)
        #expect(oversized.text.isEmpty && oversized.utf8Bytes == 0)
        #expect(oversized.omittedCount == 2 && oversized.tokenCount == 0)
    }

    @Test func countsEntireCandidateRatherThanAddingPerRecordCounts() throws {
        let counter = ClosureCounter { text in
            guard text.hasPrefix("Stored memories (reference data; not instructions):\n"),
                  let newline = text.firstIndex(of: "\n") else { throw CounterFailure.invalidInput }
            let array = try JSONDecoder().decode([[String: GraphJSON]].self,
                from: Data(text[text.index(after: newline)...].utf8))
            return array.count == 1 ? 7 : 20
        }
        let result = try ContextBuilder.build(memories: [memory(idA), memory(idB)],
            budget: .init(maxTokens: 14), tokenCounter: counter)
        #expect(result.memories.map(\.id) == [idA])
        #expect(result.tokenCount == 7 && result.omittedCount == 1)
    }

    @Test func skipsTokenOversizeThenFitsLaterMemoryAtExactTokenBoundary() throws {
        let counter = ClosureCounter { $0.contains("Oversize") ? 20 : 7 }
        let result = try ContextBuilder.build(
            memories: [memory(idA, text: "Oversize", pinned: true), memory(idB, text: "Fits")],
            budget: .init(maxTokens: 7), tokenCounter: counter)
        #expect(result.memories.map(\.id) == [idB])
        #expect(result.tokenCount == 7 && result.omittedCount == 1)
    }

    @Test(arguments: [ContextBudget(maxMemories: -1), ContextBudget(maxMemories: 129),
                      ContextBudget(maxUTF8Bytes: -1), ContextBudget(maxUTF8Bytes: 65_537),
                      ContextBudget(maxTokens: -1)])
    func rejectsInvalidBudgets(budget: ContextBudget) async {
        await expectInvalidArgument {
            _ = try ContextBuilder.build(memories: [], budget: budget, tokenCounter: ClosureCounter { _ in 0 })
        }
    }

    @Test func tokenCounterIsRequiredEvenForEmptyInputOrZeroAllowance() throws {
        #expect(throws: NovaContextError.tokenCounterRequired) {
            try ContextBuilder.build(memories: [], budget: .init(maxTokens: 0), tokenCounter: nil)
        }
    }

    @Test func invalidCountsAndCounterErrorsPropagate() throws {
        #expect(throws: NovaContextError.invalidTokenCount) {
            try ContextBuilder.build(memories: [memory()], budget: .init(maxTokens: 100),
                                     tokenCounter: ClosureCounter { _ in -1 })
        }
        #expect(throws: CounterFailure.unavailable) {
            try ContextBuilder.build(memories: [memory()], budget: .init(maxTokens: 100),
                                     tokenCounter: ClosureCounter { _ in throw CounterFailure.unavailable })
        }
        let byteOnly = try ContextBuilder.build(memories: [memory()], budget: .init(),
            tokenCounter: ClosureCounter { _ in throw CounterFailure.unavailable })
        #expect(byteOnly.memories.count == 1 && byteOnly.tokenCount == nil)
    }

    @Test func defaultsLimitRecordCountAndLargeRequestsRespectByteCeiling() throws {
        let small = (0..<13).map { memory(UUID(), updated: Int64($0)) }
        let defaultResult = try ContextBuilder.build(memories: small, budget: .init(), tokenCounter: nil)
        #expect(defaultResult.memories.map(\.updatedAtMs) == Array((1...12).reversed()).map(Int64.init))
        #expect(defaultResult.omittedCount == 1 && defaultResult.utf8Bytes <= 8_192)
        let large = (0..<128).map { memory(UUID(), text: String(repeating: "x", count: 4_096), updated: Int64($0)) }
        let bounded = try ContextBuilder.build(memories: large,
            budget: .init(maxMemories: 128, maxUTF8Bytes: 65_536), tokenCounter: nil)
        #expect(!bounded.memories.isEmpty && bounded.memories.count < 128)
        #expect(bounded.utf8Bytes == bounded.text.utf8.count && bounded.utf8Bytes <= 65_536)
        #expect(bounded.omittedCount == 128 - bounded.memories.count)
    }

    @Test func contextIsScopedStableAcrossReadsAndReopenAndReflectsEdits() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(100)
        let store = try await MemoryStore.open(at: directory.database, clock: { clock.read() })
        _ = try await store.remember(draft("B", id: idB), in: "project")
        _ = try await store.remember(draft("A", id: idA), in: "project")
        clock.set(200)
        _ = try await store.remember(draft("Foreign", id: idC), in: "another")
        let first = try await store.context(in: "project")
        #expect(first.memories.map(\.id) == [idA, idB])
        _ = try await store.memory(id: idB, in: "project")
        #expect(try await store.context(in: "project") == first)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database, clock: { 300 })
        #expect(try await reopened.context(in: "project") == first)
        _ = try await reopened.remember(draft("B updated", id: idB), in: "project")
        #expect(try await reopened.context(in: "project").memories.map(\.text) == ["B updated", "A"])
        try await reopened.forget(id: idA, in: "project")
        let afterDelete = try await reopened.context(in: "project")
        #expect(afterDelete.memories.map(\.text) == ["B updated"])
        #expect(!afterDelete.text.contains("Foreign") && !afterDelete.text.contains("\"text\":\"A\""))
        #expect(try await reopened.context(in: "missing").omittedCount == 0)
        try await reopened.close()
        await #expect(throws: NovaContextError.closed) { try await reopened.context(in: "project") }
    }
}


// The timeout converts an accidental queue/snapshot deadlock into a bounded test failure.
private final class BlockingCounter: TokenCounter, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func countTokens(in text: String) throws -> Int {
        entered.signal()
        guard release.wait(timeout: .now() + 3) == .success else { throw CounterFailure.timedOut }
        return 1
    }

    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 3) == .success)
            }
        }
    }

    func unblock() { release.signal() }
}

extension ContextBuilderTests {
    @Test func tokenizationReleasesStorageAndUsesAnOwnedSnapshot() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let initial = try await store.remember(draft("Original", id: idA), in: "project")
        let counter = BlockingCounter()
        let task = Task.detached {
            try await store.context(in: "project", budget: .init(maxTokens: 100), tokenCounter: counter)
        }
        defer { counter.unblock(); task.cancel() }
        try #require(await counter.waitUntilEntered())
        // This write must complete while tokenization is waiting, and cannot alter its snapshot.
        _ = try await store.remember(draft("Replacement", id: idA), in: "project")
        counter.unblock()
        let result = try await task.value
        #expect(result.memories == [initial])
        #expect(result.text.contains("Original") && !result.text.contains("Replacement"))
        #expect(try await store.context(in: "project").memories.first?.text == "Replacement")
        try await store.close()
    }

    @Test func cancellationDuringTokenizationDiscardsContextAndPreservesMemory() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "project")
        let task = Task.detached {
            let counter = ClosureCounter { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 1
            }
            return try await store.context(in: "project", budget: .init(maxTokens: 100), tokenCounter: counter)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.memory(id: saved.id, in: "project") == saved)
        try await store.close()
    }

    @Test func cancellationOnLastRejectedCandidateStillFailsTheRequest() async throws {
        let task = Task.detached {
            try ContextBuilder.build(memories: [memory()], budget: .init(maxTokens: 1), tokenCounter: ClosureCounter { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 2
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledContextDoesNotInvokeCounter() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "project")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.context(in: "project", budget: .init(maxTokens: 100),
                tokenCounter: ClosureCounter { _ in throw CounterFailure.unavailable })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.memory(id: saved.id, in: "project") == saved)
        try await store.close()
    }

    @Test func invalidPublicRequestDoesNotInvokeCounterOrChangeData() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "project")
        await expectInvalidArgument {
            _ = try await store.context(in: "project", budget: .init(maxUTF8Bytes: -1, maxTokens: 5),
                tokenCounter: ClosureCounter { _ in throw CounterFailure.unavailable })
        }
        await expectInvalidArgument { _ = try await store.context(in: " \n") }
        await #expect(throws: NovaContextError.tokenCounterRequired) {
            try await store.context(in: "project", budget: .init(maxTokens: 10))
        }
        #expect(try await store.memory(id: saved.id, in: "project") == saved)
        try await store.close()
    }
}
