import Foundation
import Testing
import GraphDBKit
@testable import NovaContext

private let controlA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let controlB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let controlC = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
private let controlD = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

struct MemoryControlTests {
    @Test func listsEveryStoredMemoryIndependentlyOfContext() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let large = try await store.remember(.init(text: String(repeating: "x", count: 3_000),
            kind: .fact, origin: .user, pinned: true), in: "project")
        for index in 0..<127 { _ = try await store.remember(draft("Record \(index)"), in: "project") }
        let context = try await store.context(in: "project", budget: .init(maxMemories: 4, maxUTF8Bytes: 2_048))
        #expect(context.memories.count == 4 && !context.memories.contains { $0.id == large.id })
        let all = try await store.memories(in: "project")
        #expect(all.count == 128 && all.first?.id == large.id)
        #expect(all.first?.text.utf8.count == 3_000)
        #expect(try await store.memories(in: "missing").isEmpty)
        let edited = try #require(try await store.update(id: large.id, in: "project", text: "Now fits"))
        #expect(edited.pinned && edited.createdAtMs == large.createdAtMs)
        #expect(try await store.context(in: "project", budget: .init(maxMemories: 4, maxUTF8Bytes: 2_048)).memories.first?.id == large.id)
        try await store.forget(id: large.id, in: "project")
        #expect(try await store.memories(in: "project").count == 127)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.update(id: large.id, in: "project", text: "Do not resurrect") == nil)
        #expect(try await reopened.memories(in: "project").count == 127)
        try await reopened.close()
    }

    @Test func listUsesPinRecencyAndStableUUIDOrder() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(20)
        let store = try await MemoryStore.open(at: directory.database, clock: clock.read)
        _ = try await store.remember(draft("B", id: controlB), in: "a")
        _ = try await store.remember(draft("A", id: controlA), in: "a")
        clock.set(30)
        _ = try await store.remember(draft("D", id: controlD), in: "a")
        clock.set(10)
        _ = try await store.remember(.init(id: controlC, text: "C", kind: .fact, origin: .user, pinned: true), in: "a")
        #expect(try await store.memories(in: "a").map(\.id) == [controlC, controlD, controlA, controlB])
        _ = try await store.memory(id: controlB, in: "a")
        #expect(try await store.memories(in: "a").map(\.id) == [controlC, controlD, controlA, controlB])
        #expect(try await store.context(in: "a").memories.map(\.id) == [controlC, controlD, controlA, controlB])
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memories(in: "a").map(\.id) == [controlC, controlD, controlA, controlB])
        try await reopened.close()
    }

    @Test func targetedUpdatesPreserveFieldsAndSurviveReopen() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(10)
        let store = try await MemoryStore.open(at: directory.database, clock: clock.read)
        _ = try await store.remember(.init(id: controlA, text: "Original", kind: .toolResult,
            origin: .model, source: "cache:résumé", pinned: true), in: "a")
        clock.set(20)
        let edited = try #require(try await store.update(id: controlA, in: "a", text: "Edited"))
        #expect(edited.id == controlA && edited.scope == "a" && edited.text == "Edited")
        #expect(edited.kind == .toolResult && edited.origin == .model && edited.source == "cache:résumé")
        #expect(edited.pinned && edited.createdAtMs == 10 && edited.updatedAtMs == 20)
        clock.set(30)
        let unpinned = try #require(try await store.update(id: controlA, in: "a", pinned: false))
        #expect(unpinned.text == "Edited" && !unpinned.pinned && unpinned.createdAtMs == 10 && unpinned.updatedAtMs == 30)
        #expect(unpinned.kind == .toolResult && unpinned.origin == .model && unpinned.source == "cache:résumé")
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memories(in: "a") == [unpinned])
        try await reopened.close()
    }

    @Test func noOpAndMissingUpdateNeverWrite() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(10)
        let writes = TestClock(0)
        let store = try await MemoryStore.open(at: directory.database, clock: clock.read,
            mutation: { db, query, parameters, request in
                writes.increment()
                return try NovaStorage.executeMutation(db, query, parameters, request)
            })
        let saved = try await store.remember(draft("Unchanged", id: controlA), in: "a")
        clock.set(20)
        #expect(try await store.update(id: controlA, in: "a") == saved)
        #expect(try await store.update(id: controlA, in: "a", text: "Unchanged", pinned: false) == saved)
        #expect(try await store.update(id: controlB, in: "a", text: "Missing") == nil)
        #expect(try await store.update(id: controlA, in: "missing", pinned: true) == nil)
        #expect(try await store.memories(in: "missing").isEmpty)
        #expect(writes.read() == 1)
        try await store.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            #expect(try db.nodes(label: "NCScope").count == 1)
            #expect(try db.nodes(label: "NCMemory").count == 1)
        }
    }

    @Test(arguments: [" \n\t", String(repeating: "x", count: 4_097), String(repeating: "😀", count: 1_025)])
    func invalidTextIsRejectedEvenForMissingRecords(text: String) async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft("Keep", id: controlA), in: "a")
        await expectInvalidArgument { _ = try await store.update(id: controlA, in: "a", text: text) }
        await expectInvalidArgument { _ = try await store.update(id: controlB, in: "missing", text: text) }
        #expect(try await store.memories(in: "a") == [saved])
        #expect(try await store.memories(in: "missing").isEmpty)
        try await store.close()
    }

    @Test func representationOnlyUnicodeEditIsPersisted() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(10)
        let store = try await MemoryStore.open(at: directory.database, clock: clock.read)
        _ = try await store.remember(draft("caf\u{e9}", id: controlA), in: "a")
        clock.set(20)
        let edited = try #require(try await store.update(id: controlA, in: "a", text: "cafe\u{301}"))
        #expect(Array(edited.text.utf8) == [99, 97, 102, 101, 204, 129])
        #expect(edited.updatedAtMs == 20 && edited.createdAtMs == 10)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        let retained = try #require(try await reopened.memory(id: controlA, in: "a"))
        #expect(Array(retained.text.utf8) == [99, 97, 102, 101, 204, 129])
        try await reopened.close()
    }

    @Test func queuedControlsPreserveDisjointChangesAndDeletion() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        _ = try await store.remember(.init(id: controlA, text: "Old", kind: .message, origin: .model, source: "Source"), in: "a")
        let foreign = try await store.remember(draft("Foreign", id: controlA), in: "b")
        async let changeText = store.update(id: controlA, in: "a", text: "Changed")
        async let changePin = store.update(id: controlA, in: "a", pinned: true)
        let outcomes = try await (changeText, changePin)
        #expect(outcomes.0 != nil && outcomes.1 != nil)
        let combined = try #require(try await store.memory(id: controlA, in: "a"))
        #expect(combined.text == "Changed" && combined.pinned && combined.origin == .model && combined.source == "Source")
        _ = try await store.update(id: controlA, in: "a", text: "First")
        _ = try await store.update(id: controlA, in: "a", text: "Last")
        #expect(try await store.memory(id: controlA, in: "a")?.text == "Last")
        try await store.forget(id: controlA, in: "a")
        #expect(try await store.update(id: controlA, in: "a", text: "No resurrection", pinned: false) == nil)
        #expect(try await store.memories(in: "a").isEmpty)
        #expect(try await store.memories(in: "b") == [foreign])
        try await store.close()
    }

    @Test func controlsRejectInvalidScopesAndLifecycleStates() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        for scope in ["", " \n", String(repeating: "é", count: 65)] {
            await expectInvalidArgument { _ = try await store.memories(in: scope) }
            await expectInvalidArgument { _ = try await store.update(id: controlA, in: scope, text: "Text") }
        }
        let saved = try await store.remember(draft("Keep", id: controlA), in: "a")
        try await store.suspend()
        await #expect(throws: NovaContextError.suspended) { try await store.memories(in: "a") }
        await #expect(throws: NovaContextError.suspended) { try await store.update(id: controlA, in: "a", text: "Must not write") }
        try await store.resume()
        #expect(try await store.memories(in: "a") == [saved])
        try await store.close()
        await #expect(throws: NovaContextError.closed) { try await store.memories(in: "a") }
        await #expect(throws: NovaContextError.closed) { try await store.update(id: controlA, in: "a") }
    }
}

extension MemoryControlTests {
    @Test(arguments: [false, true])
    func invalidMembershipNeverReturnsPartialListOrAllowsUpdates(overfull: Bool) async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        _ = try await store.remember(draft("Original", id: controlA), in: "a")
        let foreign = try await store.remember(draft("Foreign", id: controlB), in: "b")
        try await store.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            if overfull {
                let sample = try #require(try db.nodes(label: "NCMemory").first { $0.properties["scope"] == .string("a") })
                _ = try db.transactionReceipt { transaction in
                    for _ in 0..<128 {
                        let id = UUID().uuidString.lowercased()
                        var properties = sample.properties
                        properties["memoryID"] = .string(id)
                        let key = "nc:scope:YQ:memory:\(id)"
                        transaction.upsertNode(label: "NCMemory", id: key, properties: properties)
                        transaction.upsertEdge(type: "NC_CONTAINS", from: "nc:scope:YQ", to: key)
                    }
                }
            } else {
                _ = try db.upsertEdge(type: "NC_CONTAINS", from: "nc:scope:YQ",
                    to: "nc:scope:Yg:memory:\(controlB.uuidString.lowercased())")
            }
        }
        let reopened = try await MemoryStore.open(at: directory.database)
        await #expect(throws: NovaContextError.invalidStore) { try await reopened.memories(in: "a") }
        await #expect(throws: NovaContextError.invalidStore) { try await reopened.update(id: controlA, in: "a", text: "Must not write") }
        #expect(try await reopened.memories(in: "b") == [foreign])
        try await reopened.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            let original = try db.queryResult("get node $id", parameters: ["id": .string("nc:scope:YQ:memory:\(controlA.uuidString.lowercased())")]).node()
            #expect(original.properties["text"] == .string("Original"))
            #expect(try db.nodes(label: "NCMemory", limit: 200).count == (overfull ? 130 : 2))
        }
    }

    @Test(arguments: [false, true])
    func ambiguousUpdateIsNotRetriedAndPreservesItsError(commitBeforeFailure: Bool) async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let seed = try await MemoryStore.open(at: directory.database, clock: { 10 })
        _ = try await seed.remember(draft("Original", id: controlA), in: "a")
        try await seed.close()
        let failure = try ambiguousMutationError()
        let attempts = TestClock(0)
        let store = try await MemoryStore.open(at: directory.database, clock: { 20 }, mutation: { db, query, parameters, request in
            attempts.increment()
            if commitBeforeFailure { _ = try NovaStorage.executeMutation(db, query, parameters, request) }
            throw failure
        })
        await #expect(throws: failure) { try await store.update(id: controlA, in: "a", text: "Changed") }
        #expect(attempts.read() == 1)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        let recovered = try #require(try await reopened.memory(id: controlA, in: "a"))
        #expect(recovered.text == (commitBeforeFailure ? "Changed" : "Original"))
        #expect(recovered.createdAtMs == 10 && recovered.updatedAtMs == (commitBeforeFailure ? 20 : 10))
        try await reopened.close()
    }

    @Test func updateWithoutReceiptIsNeverAcknowledged() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let seed = try await MemoryStore.open(at: directory.database)
        let saved = try await seed.remember(draft("Original", id: controlA), in: "a")
        try await seed.close()
        let attempts = TestClock(0)
        let store = try await MemoryStore.open(at: directory.database, clock: { 20 }, mutation: { db, _, _, request in
            attempts.increment()
            return try db.queryResult("get node 'nc:metadata'", request: request)
        })
        await #expect(throws: NovaContextError.invalidStore) { try await store.update(id: controlA, in: "a", pinned: true) }
        #expect(attempts.read() == 1)
        #expect(try await store.memory(id: controlA, in: "a") == saved)
        try await store.close()
    }

    @Test func newControlsPreserveByteDistinctScopes() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        _ = try await store.remember(draft("Composed", id: controlA), in: "caf\u{e9}")
        let decomposed = try await store.remember(draft("Decomposed", id: controlA), in: "cafe\u{301}")
        _ = try await store.update(id: controlA, in: "caf\u{e9}", text: "Edited", pinned: true)
        #expect(try await store.memories(in: "caf\u{e9}").first?.text == "Edited")
        #expect(try await store.memories(in: "cafe\u{301}") == [decomposed])
        try await store.close()
    }

    @Test func alreadyCancelledControlsPreserveData() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft("Keep", id: controlA), in: "a")
        let listCancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await store.memories(in: "a"); return false }
            catch is CancellationError { return true }
            catch let error as GraphCoreError { return error.code == "cancelled" }
            catch { Issue.record("Unexpected error: \(error)"); return false }
        }.value
        let updateCancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await store.update(id: controlA, in: "a", text: "Must not write"); return false }
            catch is CancellationError { return true }
            catch let error as GraphCoreError { return error.code == "cancelled" }
            catch { Issue.record("Unexpected error: \(error)"); return false }
        }.value
        #expect(listCancelled && updateCancelled)
        #expect(try await store.memory(id: controlA, in: "a") == saved)
        try await store.close()
    }

    @Test func committedUpdateRetainsItsOutcomeAfterLateCancellation() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let seed = try await MemoryStore.open(at: directory.database, clock: { 10 })
        _ = try await seed.remember(draft("Original", id: controlA), in: "a")
        try await seed.close()
        let store = try await MemoryStore.open(at: directory.database, clock: { 20 }, mutation: { db, query, parameters, request in
            let receipt = try NovaStorage.executeMutation(db, query, parameters, request)
            request.cancel()
            return receipt
        })
        let updated = try #require(try await store.update(id: controlA, in: "a", text: String(repeating: "😀", count: 1_024), pinned: true))
        #expect(updated.text.utf8.count == 4_096 && updated.pinned && updated.createdAtMs == 10 && updated.updatedAtMs == 20)
        #expect(try await store.memory(id: controlA, in: "a") == updated)
        try await store.close()
    }
}
