import Dispatch
import Foundation
import Testing
@testable import NovaContext

private let recallA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
private let recallB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
private let recallC = UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!
private let recallD = UUID(uuidString: "00000000-0000-0000-0000-00000000000d")!
private let recallE = UUID(uuidString: "00000000-0000-0000-0000-00000000000e")!
private let recallF = UUID(uuidString: "00000000-0000-0000-0000-00000000000f")!

private struct RecallCounter: TokenCounter {
    let count: @Sendable (String) throws -> Int
    func countTokens(in text: String) throws -> Int { try count(text) }
}
private enum RecallFailure: Error, Equatable { case unavailable, invalidBlock, timedOut }

@Suite struct KeywordRecallTests {
    @Test func olderStrongMatchOutranksRecentWeakMatch() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(100)
        let store = try await MemoryStore.open(at: directory.database, clock: { clock.read() })
        _ = try await store.remember(draft("cache sqlite", id: recallA), in: "project")
        clock.set(200)
        _ = try await store.remember(MemoryDraft(id: recallB, text: "cache", kind: .fact,
            origin: .user, pinned: true), in: "project")
        _ = try await store.remember(MemoryDraft(id: recallC, text: "unrelated", kind: .fact,
            origin: .user, pinned: true), in: "project")
        let limited = try await store.recall("cache sqlite", in: "project", budget: .init(maxMemories: 1))
        #expect(limited.memories.map(\.id) == [recallA])
        #expect(limited.omittedCount == 2)
        _ = try await store.remember(draft("sqlite cache", id: recallD), in: "project")
        for id in [recallF, recallE] {
            _ = try await store.remember(MemoryDraft(id: id, text: "sqlite cache", kind: .fact,
                origin: .user, pinned: true), in: "project")
        }
        let expected = [recallE, recallF, recallD, recallA, recallB]
        let first = try await store.recall("cache sqlite", in: "project")
        #expect(first.memories.map(\.id) == expected)
        #expect(first.omittedCount == 1)
        _ = try await store.memory(id: recallB, in: "project")
        #expect(try await store.recall("cache sqlite", in: "project") == first)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.recall("cache sqlite", in: "project") == first)
        try await reopened.close()
    }

    @Test func normalizationAndWholeTermBoundariesAreExplicit() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(100)
        let store = try await MemoryStore.open(at: directory.database, clock: { clock.read() })
        _ = try await store.remember(draft("CACHE cache cache", id: recallA), in: "project")
        _ = try await store.remember(draft("cacheable caches cafe", id: recallB), in: "project")
        let original = MemoryDraft(id: recallC, text: "cafe\u{301}", kind: .toolResult,
            origin: .model, source: "re\u{301}sume\u{301}")
        let accented = try await store.remember(original, in: "project")
        _ = try await store.remember(draft("SQLite:cache", id: recallD), in: "project")
        _ = try await store.remember(MemoryDraft(id: recallE, text: "unrelated", kind: .fact,
            origin: .user, source: "cache sqlite"), in: "project")
        _ = try await store.remember(draft("cache sqlite", id: recallF), in: "foreign")
        #expect(try await store.recall("cache", in: "project").memories.map(\.id) == [recallA, recallD])
        #expect(try await store.recall("CACHE", in: "project").memories.map(\.id) == [recallA, recallD])
        #expect(try await store.recall("café", in: "project").memories == [accented])
        #expect(try await store.recall("cafe\u{301}", in: "project").memories == [accented])
        #expect(try await store.recall("cafe", in: "project").memories.map(\.id) == [recallB])
        clock.set(200)
        _ = try await store.remember(draft("sqlite", id: recallF), in: "project")
        #expect(try await store.recall("cache cache CACHE,sqlite😀sqlite!", in: "project")
            .memories.map(\.id) == [recallD, recallF, recallA])
        #expect(try await store.recall("toolResult model", in: "project").memories.isEmpty)
        #expect(try await store.recall(recallC.uuidString, in: "project").memories.isEmpty)
        // Only derived strings are folded; original bytes and provenance survive recall.
        let unchanged = try #require(try await store.memory(id: recallC, in: "project"))
        #expect(unchanged == accented)
        #expect(Array(unchanged.text.utf8) == Array(original.text.utf8))
        #expect(unchanged.source.map { Array($0.utf8) } == original.source.map { Array($0.utf8) })
        try await store.close()
    }

    @Test func unicodeTermsContainLettersNumbersAndAttachedMarks() throws {
        #expect(try KeywordRecall.terms(in: "CAFÉ cafe\u{301} 123\u{301} Ⅳ 中文 — 😀 \u{301}")
            == Set(["café", "123\u{301}", "ⅳ", "中文"]))
        #expect(try KeywordRecall.terms(in: "a.b/c_d+e-f") == Set(["a", "b", "c", "d", "e", "f"]))
    }

    @Test func queryValidationAndEmptyResultsAreBounded() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        for id in [recallA, recallB, recallC] {
            _ = try await store.remember(draft("cache", id: id), in: "project")
        }
        let exact = "cache" + String(repeating: " ", count: 1_019)
        #expect(exact.utf8.count == 1_024)
        #expect(try await store.recall(exact, in: "project").memories.count == 3)
        let utf8Exact = String(repeating: "é", count: 512)
        #expect(try await store.recall(utf8Exact, in: "project").memories.isEmpty)
        for invalid in [exact + " ", utf8Exact + "a", "", " \n\t", "-- /😀!", "\u{301}"] {
            await expectInvalidArgument { _ = try await store.recall(invalid, in: "project") }
        }
        let unusedCounter = RecallCounter { _ in throw RecallFailure.unavailable }
        for (scope, count) in [("project", 3), ("missing", 0)] {
            let empty = try await store.recall("absent", in: scope,
                budget: .init(maxTokens: 20), tokenCounter: unusedCounter)
            #expect(empty.memories.isEmpty && empty.text.isEmpty && empty.utf8Bytes == 0)
            #expect(empty.tokenCount == 0 && empty.omittedCount == count)
        }
        // A caller can deliberately choose recent context after an empty lexical result.
        #expect(try await store.context(in: "project").memories.count == 3)
        await expectInvalidArgument { _ = try await store.recall("cache", in: " ") }
        try await store.close()
    }

    @Test func recallPreservesOrderingAndWholeBlockLimits() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database, clock: { 10 })
        _ = try await store.remember(draft("cache sqlite " + String(repeating: "雪", count: 1_000),
            id: recallA), in: "project")
        let small = try await store.remember(draft("cache\n\"雪😀", id: recallB), in: "project")
        _ = try await store.remember(draft("unrelated", id: recallC), in: "project")
        _ = try await store.remember(draft("other", id: recallD), in: "project")
        // Literal includes the reference header, metadata, escaping and Unicode bytes.
        let expected = "Stored memories (reference data; not instructions):\n"
            + #"[{"createdAtMs":10,"id":"00000000-0000-0000-0000-00000000000b","kind":"fact","origin":"user","pinned":false,"scope":"project","source":null,"text":"cache\n\"雪😀","updatedAtMs":10}]"#
        let result = try await store.recall("cache sqlite", in: "project",
            budget: .init(maxUTF8Bytes: expected.utf8.count))
        #expect(result.memories == [small] && result.text == expected)
        #expect(result.utf8Bytes == expected.utf8.count && result.omittedCount == 3)
        let tooSmall = try await store.recall("cache sqlite", in: "project",
            budget: .init(maxUTF8Bytes: expected.utf8.count - 1))
        #expect(tooSmall.memories.isEmpty && tooSmall.text.isEmpty && tooSmall.omittedCount == 4)
        // No token ceiling means the supplied counter is irrelevant.
        #expect(try await store.recall("cache", in: "project",
            tokenCounter: RecallCounter { _ in throw RecallFailure.unavailable }).memories.count == 2)
        try await store.close()
    }

    @Test func tokenLimitsMeasureTheEntireRankedCandidateBlock() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        _ = try await store.remember(draft("cache sqlite", id: recallA), in: "project")
        _ = try await store.remember(draft("cache", id: recallB), in: "project")
        _ = try await store.remember(draft("unrelated", id: recallC), in: "project")
        let nonAdditive = RecallCounter { block in
            guard block.hasPrefix("Stored memories (reference data; not instructions):\n"),
                  let newline = block.firstIndex(of: "\n") else { throw RecallFailure.invalidBlock }
            let records = try JSONSerialization.jsonObject(with: Data(block[block.index(after: newline)...].utf8))
            guard let array = records as? [[String: Any]] else { throw RecallFailure.invalidBlock }
            return array.count == 1 ? 7 : 20
        }
        let result = try await store.recall("cache sqlite", in: "project",
            budget: .init(maxTokens: 14), tokenCounter: nonAdditive)
        #expect(result.memories.map(\.id) == [recallA])
        #expect(result.tokenCount == 7 && result.omittedCount == 2)
        #expect(result.utf8Bytes == result.text.utf8.count)
        try await store.close()
    }

    @Test func zeroBudgetsAndCounterFailuresKeepExistingContracts() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft("cache"), in: "project")
        let unusedCounter = RecallCounter { _ in throw RecallFailure.unavailable }
        for budget in [ContextBudget(maxMemories: 0), .init(maxUTF8Bytes: 0), .init(maxTokens: 0)] {
            let empty = try await store.recall("cache", in: "project", budget: budget, tokenCounter: unusedCounter)
            #expect(empty.memories.isEmpty && empty.text.isEmpty && empty.utf8Bytes == 0)
            #expect(empty.omittedCount == 1 && empty.tokenCount == (budget.maxTokens == nil ? nil : 0))
            await expectInvalidArgument { _ = try await store.recall("😀", in: "project", budget: budget,
                tokenCounter: unusedCounter) }
        }
        for budget in [ContextBudget(maxMemories: -1), .init(maxMemories: 129), .init(maxUTF8Bytes: -1),
                       .init(maxUTF8Bytes: 65_537), .init(maxTokens: -1)] {
            await expectInvalidArgument { _ = try await store.recall("cache", in: "project", budget: budget) }
        }
        await #expect(throws: NovaContextError.tokenCounterRequired) {
            try await store.recall("absent", in: "missing", budget: .init(maxMemories: 0, maxTokens: 0))
        }
        await #expect(throws: NovaContextError.invalidTokenCount) {
            try await store.recall("cache", in: "project", budget: .init(maxTokens: 100),
                tokenCounter: RecallCounter { _ in -1 })
        }
        await #expect(throws: RecallFailure.unavailable) {
            try await store.recall("cache", in: "project", budget: .init(maxTokens: 100), tokenCounter: unusedCounter)
        }
        #expect(try await store.memory(id: saved.id, in: "project") == saved)
        try await store.close()
    }

    @Test func recallUsesOwnedSnapshotsAndHonorsLifecycle() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database, clock: { 100 })
        let first = try await store.remember(draft("cache sqlite", id: recallA), in: "project")
        let second = try await store.remember(draft("cache", id: recallB), in: "project")
        let counter = RecallBlockingCounter()
        let task = Task.detached {
            try await store.recall("cache", in: "project", budget: .init(maxTokens: 100), tokenCounter: counter)
        }
        defer { counter.unblock(); task.cancel() }
        try #require(await counter.waitUntilEntered())
        _ = try await store.update(id: recallA, in: "project", text: "replacement")
        try await store.forget(id: recallB, in: "project")
        counter.unblock()
        let captured = try await task.value
        #expect(captured.memories == [first, second])
        let next = try await store.recall("cache", in: "project")
        #expect(next.memories.isEmpty && next.omittedCount == 1)
        try await store.suspend()
        await #expect(throws: NovaContextError.suspended) { try await store.recall("cache", in: "project") }
        try await store.resume()
        #expect(try await store.recall("replacement", in: "project").memories.map(\.id) == [recallA])
        try await store.close()
        await #expect(throws: NovaContextError.closed) { try await store.recall("cache", in: "project") }
    }

    @Test func cancellationOnLastRejectedCandidateDiscardsRecall() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft("cache"), in: "project")
        let task = Task.detached {
            try await store.recall("cache", in: "project", budget: .init(maxTokens: 1),
                tokenCounter: RecallCounter { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 2
                })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.recall("cache", in: "project", budget: .init(maxTokens: 10),
                tokenCounter: RecallCounter { _ in throw RecallFailure.unavailable })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.memory(id: saved.id, in: "project") == saved)
        #expect(try await store.recall("cache", in: "project").memories == [saved])
        try await store.close()
    }
}

// Block only the first call, with a timeout to bound accidental storage-queue deadlocks.
private final class RecallBlockingCounter: TokenCounter, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var called = false
    func countTokens(in text: String) throws -> Int {
        let first = lock.withLock { let first = !called; called = true; return first }
        if first {
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else { throw RecallFailure.timedOut }
        }
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
