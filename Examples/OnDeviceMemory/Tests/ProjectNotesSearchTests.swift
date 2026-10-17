import Foundation
import FoundationModels
import Testing
import NovaContext
@testable import OnDeviceMemory

private struct ProjectNotesTestStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectNotesSearch-\(UUID())")
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private enum SearchReaderFailure: Error, Equatable {
    case unavailable
}

/// Gates only the asynchronous read boundary; the tool and admission actor remain real.
private actor ProjectNotesReaderProbe {
    let payload: ContextPayload
    let gated: Bool
    let failure: SearchReaderFailure?
    private(set) var queries: [String] = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ payload: ContextPayload, gated: Bool = false, failure: SearchReaderFailure? = nil) {
        self.payload = payload
        self.gated = gated
        self.failure = failure
    }

    func read(_ query: String) async throws -> ContextPayload {
        queries.append(query)
        if gated {
            await withCheckedContinuation { continuation in
                pending[query] = continuation
                notifyObservers()
            }
        } else {
            notifyObservers()
        }
        if let failure { throw failure }
        return payload
    }

    func waitForReads(_ count: Int) async {
        if queries.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func release(_ query: String) { pending.removeValue(forKey: query)?.resume() }

    private func notifyObservers() {
        let ready = observers.filter { queries.count >= $0.0 }
        observers.removeAll { queries.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
}

struct ProjectNotesSearchTests {
    @Test func nativeToolReturnsExactScopedRecall() async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        let note = try await store.remember(.init(text: "Cache choice: Riverstone.", kind: .toolResult,
            origin: .model, source: "Reviewed project note", pinned: true), in: "project:demo")
        _ = try await store.remember(.init(text: "Cache choice: Foreign secret.", kind: .fact,
            origin: .user), in: "other")
        let before = try await store.memories(in: "project:demo")
        let expected = try await store.recall("cache", in: "project:demo",
            budget: ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048))
        let search = ProjectNotesSearch { query in
            try await store.recall(query, in: "project:demo",
                budget: ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048))
        }
        let tool = SearchProjectNotes(search: search)
        #expect(tool.name == "search_project_notes")
        let output = try await tool.call(arguments: .init(query: "cache"))
        #expect(output == expected.text)
        #expect(output.contains(note.id.uuidString.lowercased()))
        #expect(output.contains("Reviewed project note") && output.contains("\"origin\":\"model\""))
        #expect(!output.contains("Foreign secret") && !output.contains("\"scope\":\"other\""))
        let calls = await search.finish()
        #expect(calls.count == 1 && calls[0].query == "cache")
        #expect(calls[0].status == .succeeded(output: output, memoryIDs: [note.id]))
        try await store.close()
        let reopened = try await MemoryStore.open(at: temporary.directory)
        let after = try await reopened.memories(in: "project:demo")
        let foreign = try await reopened.memories(in: "other")
        #expect(after == before && foreign.count == 1)
        try await reopened.close()
    }

    @Test func emptyResultIsExplicit() async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        _ = try await store.remember(.init(text: "Unrelated pinned decision.", kind: .fact,
            origin: .user, pinned: true), in: "project:demo")
        let search = ProjectNotesSearch { query in
            try await store.recall(query, in: "project:demo",
                budget: ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048))
        }
        let output = try await search.search(query: "cache")
        #expect(output == "No matching project notes.")
        let calls = await search.finish()
        #expect(calls[0].status == .succeeded(output: "No matching project notes.", memoryIDs: []))
        try await store.close()
    }

    @Test func queryValidationConsumesAttempts() async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        let empty = try await store.context(in: "project:demo")
        let validProbe = ProjectNotesReaderProbe(empty)
        let valid = ProjectNotesSearch { try await validProbe.read($0) }
        let boundary = String(repeating: "é", count: 512)
        #expect(boundary.utf8.count == 1_024)
        _ = try await valid.search(query: boundary)
        let acceptedQueries = await validProbe.queries
        #expect(acceptedQueries == [boundary])
        _ = await valid.finish()

        let invalidProbe = ProjectNotesReaderProbe(empty)
        let invalid = ProjectNotesSearch { try await invalidProbe.read($0) }
        await #expect(throws: ProjectNotesSearchError.invalidQuery) {
            try await invalid.search(query: boundary + "x")
        }
        await #expect(throws: ProjectNotesSearchError.invalidQuery) {
            try await invalid.search(query: " \n\t")
        }
        await #expect(throws: ProjectNotesSearchError.attemptLimitReached) {
            try await invalid.search(query: "cache")
        }
        let rejectedQueries = await invalidProbe.queries
        #expect(rejectedQueries.isEmpty)
        let invalidCalls = await invalid.finish()
        #expect(invalidCalls.count == 2)
        #expect(invalidCalls[0].query == nil && invalidCalls[1].query == " \n\t")
        for call in invalidCalls {
            guard case .failed(let message) = call.status else {
                Issue.record("Invalid queries must have a visible failure")
                continue
            }
            #expect(!message.isEmpty && message.utf8.count <= 256)
        }

        let lexical = ProjectNotesSearch { query in try await store.recall(query, in: "project:demo") }
        await #expect(throws: NovaContextError.self) { try await lexical.search(query: "!?😀") }
        #expect(try await lexical.search(query: "cache") == "No matching project notes.")
        await #expect(throws: ProjectNotesSearchError.attemptLimitReached) {
            try await lexical.search(query: "cache")
        }
        _ = await lexical.finish()
        try await store.close()
    }

    @Test func concurrentAdmissionAllowsOnlyTwoReads() async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        let empty = try await store.context(in: "project:demo")
        let probe = ProjectNotesReaderProbe(empty, gated: true)
        let search = ProjectNotesSearch { try await probe.read($0) }
        let first = Task { try await search.search(query: "first") }
        await probe.waitForReads(1)
        let second = Task { try await search.search(query: "second") }
        await probe.waitForReads(2)
        await #expect(throws: ProjectNotesSearchError.attemptLimitReached) {
            try await search.search(query: "third")
        }
        // Complete in reverse order to distinguish admission order from completion order.
        await probe.release("second")
        #expect(try await second.value == "No matching project notes.")
        await probe.release("first")
        #expect(try await first.value == "No matching project notes.")
        let reads = await probe.queries
        let calls = await search.finish()
        #expect(reads == ["first", "second"])
        #expect(calls.map(\.id) == [1, 2] && calls.map(\.query) == ["first", "second"])
        await #expect(throws: ProjectNotesSearchError.inactive) { try await search.search(query: "late") }
        #expect(await search.finish() == calls)
        try await store.close()
    }

    @Test func returnedTextIsWholeAndByteBounded() async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        let original = "cache \"quoted\"\n café 😀 "
        let memory = try await store.remember(.init(text: original, kind: .fact,
            origin: .application), in: "project:demo")
        let budget = ContextBudget(maxMemories: 4, maxUTF8Bytes: 65_536)
        let initial = try await store.context(in: "project:demo", budget: budget)
        let padding = 2_048 - initial.utf8Bytes
        #expect(padding > 0)
        _ = try await store.update(id: memory.id, in: "project:demo",
            text: original + String(repeating: "x", count: padding))
        let exact = try await store.context(in: "project:demo", budget: budget)
        #expect(exact.utf8Bytes == 2_048)
        let search = ProjectNotesSearch { _ in exact }
        let output = try await search.search(query: "cache")
        #expect(output == exact.text && output.utf8.count == 2_048)
        let json = try #require(output.split(separator: "\n", maxSplits: 1).last)
        let records = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(records[0]["text"] as? String == original + String(repeating: "x", count: padding))
        _ = await search.finish()

        _ = try await store.update(id: memory.id, in: "project:demo",
            text: original + String(repeating: "x", count: padding + 1))
        let oversized = try await store.context(in: "project:demo", budget: budget)
        #expect(oversized.utf8Bytes == 2_049)
        let overflow = ProjectNotesSearch { _ in oversized }
        await #expect(throws: ProjectNotesSearchError.resultTooLarge) {
            try await overflow.search(query: "cache")
        }
        let failed = await overflow.finish()
        guard case .failed = failed[0].status else {
            Issue.record("An oversized result must be a failure, not truncated output")
            try await store.close()
            return
        }
        try await store.close()
    }

    @Test(arguments: [false, true])
    func cancellationAndFinishDiscardLateResults(finishRequest: Bool) async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        let empty = try await store.context(in: "project:demo")
        let probe = ProjectNotesReaderProbe(empty, gated: true)
        let search = ProjectNotesSearch { try await probe.read($0) }
        let task = Task { try await search.search(query: "cache") }
        await probe.waitForReads(1)
        var snapshot: [ProjectNotesSearchCall]?
        if finishRequest {
            snapshot = await search.finish()
            #expect(snapshot?.first?.status == .discarded)
        } else {
            task.cancel()
        }
        await probe.release("cache")
        do {
            _ = try await task.value
            Issue.record("A cancelled or ended request cannot return a late successful result")
        } catch {
            if finishRequest {
                #expect(error as? ProjectNotesSearchError == .inactive)
            } else {
                #expect(error is CancellationError)
            }
        }
        let ended = await search.finish()
        #expect(ended.first?.status == .discarded)
        if let snapshot { #expect(ended == snapshot) }
        #expect(await search.finish() == ended)
        await #expect(throws: ProjectNotesSearchError.inactive) { try await search.search(query: "late") }
        let reads = await probe.queries
        #expect(reads == ["cache"])

        // Cancellation already present at entry must not charge or invoke the reader.
        let start = ProjectNotesReaderProbe(empty, gated: true)
        let unused = ProjectNotesReaderProbe(empty)
        let precancelled = ProjectNotesSearch { try await unused.read($0) }
        let cancelledTask = Task {
            _ = try await start.read("start")
            return try await precancelled.search(query: "cache")
        }
        await start.waitForReads(1)
        cancelledTask.cancel()
        await start.release("start")
        await #expect(throws: CancellationError.self) { try await cancelledTask.value }
        #expect(await precancelled.finish().isEmpty)
        let unusedReads = await unused.queries
        #expect(unusedReads.isEmpty)
        try await store.close()
    }

    @Test func readerFailureIsVisibleWithoutRetry() async throws {
        let temporary = ProjectNotesTestStore()
        defer { temporary.remove() }
        let store = try await MemoryStore.open(at: temporary.directory)
        let empty = try await store.context(in: "project:demo")
        let probe = ProjectNotesReaderProbe(empty, failure: .unavailable)
        let search = ProjectNotesSearch { try await probe.read($0) }
        await #expect(throws: SearchReaderFailure.unavailable) { try await search.search(query: "cache") }
        let queries = await probe.queries
        let calls = await search.finish()
        #expect(queries == ["cache"] && calls.count == 1)
        guard case .failed(let message) = calls[0].status else {
            Issue.record("The reader failure must remain observable")
            try await store.close()
            return
        }
        #expect(!message.isEmpty && message.utf8.count <= 256)
        #expect(try await store.memories(in: "project:demo").isEmpty)
        try await store.close()
    }
}
