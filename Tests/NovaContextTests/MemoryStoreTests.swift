import Foundation
import Testing
import GraphDBKit
@testable import NovaContext

@Suite struct MemoryStoreTests {
    @Test func acknowledgedMemorySurvivesReopen() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(1_000)
        let store = try await MemoryStore.open(at: directory.database, clock: { clock.read() })
        let input = MemoryDraft(text: "Keep data on device", kind: .fact, origin: .user,
                                source: "Project decision", pinned: true)
        let saved = try await store.remember(input, in: "project:nova")
        #expect(saved.text == "Keep data on device")
        #expect(saved.createdAtMs == 1_000)
        #expect(saved.updatedAtMs == 1_000)
        #expect(saved.scope == "project:nova")
        #expect(saved.kind == .fact && saved.origin == .user)
        #expect(saved.source == "Project decision" && saved.pinned)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: input.id, in: "project:nova") == saved)
        try await reopened.close()
    }

    @Test func replacementPreservesCreationAndReplacesAllContent() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let clock = TestClock(100)
        let store = try await MemoryStore.open(at: directory.database, clock: { clock.read() })
        var input = MemoryDraft(text: "Old", kind: .fact, origin: .user, source: "Old source", pinned: true)
        _ = try await store.remember(input, in: "a")
        clock.set(200)
        input.text = "New"; input.source = nil; input.pinned = false
        input.kind = .toolResult; input.origin = .application
        let updated = try await store.remember(input, in: "a")
        #expect(updated.createdAtMs == 100 && updated.updatedAtMs == 200)
        #expect(updated.text == "New" && updated.source == nil && !updated.pinned)
        #expect(updated.kind == .toolResult && updated.origin == .application)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: input.id, in: "a") == updated)
        try await reopened.close()
    }

    @Test func sameIDAcrossScopesIsIndependent() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let id = UUID()
        _ = try await store.remember(draft("One", id: id), in: "Project")
        let other = try await store.remember(draft("Two", id: id), in: "project")
        #expect(try await store.memory(id: id, in: "Project")?.text == "One")
        #expect(try await store.memory(id: id, in: "project") == other)
        #expect(try await store.memory(id: id, in: "unknown") == nil)
        try await store.forget(id: id, in: "Project")
        try await store.forget(id: id, in: "Project")
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: id, in: "Project") == nil)
        #expect(try await reopened.memory(id: id, in: "project") == other)
        try await reopened.close()
    }

    @Test func clearIsScopedAndDurable() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let a = try await store.remember(draft(), in: "a")
        let b = try await store.remember(draft(), in: "a")
        let retained = try await store.remember(draft(), in: "b")
        try await store.clear(scope: "a")
        try await store.clear(scope: "a")
        try await store.clear(scope: "missing")
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: a.id, in: "a") == nil)
        #expect(try await reopened.memory(id: b.id, in: "a") == nil)
        #expect(try await reopened.memory(id: retained.id, in: "b") == retained)
        try await reopened.close()
    }

    @Test func bindingsPreserveLiteralTextAndScope() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let text = "雪😀\n\"; delete node nc:metadata; // \\ $id \u{0}"
        let scope = "app:雪/\"; // $scope"
        let saved = try await store.remember(MemoryDraft(text: text, kind: .message,
                                                       origin: .model, source: text), in: scope)
        #expect(saved.text == text && saved.scope == scope)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: saved.id, in: scope) == saved)
        try await reopened.close()
    }
}


extension MemoryStoreTests {
    @Test func capacityRejectsNewRecordsButAllowsReplacementAndReclaimedSpace() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        var ids: [UUID] = []
        for index in 0..<128 {
            let saved = try await store.remember(draft("Record \(index)"), in: "full")
            ids.append(saved.id)
        }
        await #expect(throws: NovaContextError.scopeFull) {
            try await store.remember(draft("Too many"), in: "full")
        }
        _ = try await store.remember(draft("Replacement", id: ids[0]), in: "full")
        try await store.forget(id: ids[1], in: "full")
        let added = try await store.remember(draft("Reclaimed slot"), in: "full")
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: ids[0], in: "full")?.text == "Replacement")
        #expect(try await reopened.memory(id: ids[1], in: "full") == nil)
        #expect(try await reopened.memory(id: added.id, in: "full") == added)
        await #expect(throws: NovaContextError.scopeFull) {
            try await reopened.remember(draft(), in: "full")
        }
        try await reopened.clear(scope: "full")
        #expect(try await reopened.memory(id: added.id, in: "full") == nil)
        _ = try await reopened.remember(draft("Fresh scope"), in: "full")
        try await reopened.close()
    }

    @Test func concurrentAdmissionDoesNotExceedCapacity() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        for _ in 0..<127 { _ = try await store.remember(draft(), in: "race") }
        let outcomes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { _ = try await store.remember(draft(), in: "race"); return true }
                    catch NovaContextError.scopeFull { return false }
                }
            }
            var results: [Bool] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(outcomes.filter { !$0 }.count == 1)
        try await store.close()
    }

    @Test func utf8AndWhitespaceValidationDoesNotMutateExistingMemory() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft("Preserve me"), in: "a")
        for text in ["", " \n\t", String(repeating: "a", count: 4097), String(repeating: "😀", count: 1025)] {
            await expectInvalidArgument { _ = try await store.remember(draft(text, id: saved.id), in: "a") }
        }
        for scope in ["", " \n", String(repeating: "😀", count: 33)] {
            await expectInvalidArgument { _ = try await store.remember(draft(), in: scope) }
            await expectInvalidArgument { _ = try await store.memory(id: saved.id, in: scope) }
            await expectInvalidArgument { try await store.forget(id: saved.id, in: scope) }
            await expectInvalidArgument { try await store.clear(scope: scope) }
        }
        await expectInvalidArgument {
            _ = try await store.remember(MemoryDraft(id: saved.id, text: "Changed", kind: .fact,
                                                    origin: .user, source: String(repeating: "😀", count: 129)), in: "a")
        }
        #expect(try await store.memory(id: saved.id, in: "a") == saved)
        let exact = MemoryDraft(text: String(repeating: "😀", count: 1024), kind: .fact, origin: .user,
                                source: String(repeating: "😀", count: 128))
        let boundary = try await store.remember(exact, in: String(repeating: "😀", count: 32))
        #expect(boundary.text == exact.text && boundary.source == exact.source)
        try await store.close()
    }

    @Test func futureSchemaAndUnrelatedDataAreNotReinitialized() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            _ = try db.queryResult("upsert node NCMetadata 'nc:metadata' set schemaVersion=2; upsert node Other sentinel set text='keep'")
        }
        await #expect(throws: NovaContextError.unsupportedSchema(2)) {
            try await MemoryStore.open(at: directory.database)
        }
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            #expect(try db.node(id: "nc:metadata")?.properties["schemaVersion"] == .int(2))
            #expect(try db.node(id: "sentinel")?.properties["text"] == .string("keep"))
        }
        let other = directory.root.appendingPathComponent("other.novacontext")
        try withRawDatabase(other) { (db: GraphDatabase) throws in _ = try db.upsertNode(label: "Other", id: "sentinel") }
        await #expect(throws: NovaContextError.invalidStore) { try await MemoryStore.open(at: other) }
        try withRawDatabase(other) { (db: GraphDatabase) throws in
            #expect(try db.node(id: "sentinel") != nil)
            #expect(try db.node(id: "nc:metadata") == nil)
        }
    }

    @Test func indexOnlyDatabaseIsNotClaimedAsEmpty() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in _ = try db.queryResult("create index on Person (name)") }
        await #expect(throws: NovaContextError.invalidStore) { try await MemoryStore.open(at: directory.database) }
    }

    @Test func closeIsIdempotentAndRejectsLaterOperations() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "a")
        try await store.close()
        try await store.close()
        await #expect(throws: NovaContextError.closed) { try await store.memory(id: saved.id, in: "a") }
        await #expect(throws: NovaContextError.closed) { try await store.remember(draft(), in: "a") }
        await #expect(throws: NovaContextError.closed) { try await store.forget(id: saved.id, in: "a") }
        await #expect(throws: NovaContextError.closed) { try await store.clear(scope: "a") }
    }

    @Test func malformedStoredRecordFailsWithoutOverwritingIt() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "a")
        try await store.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            let node = try #require(try db.nodes(label: "NCMemory").first)
            var properties = node.properties
            properties["text"] = .string("")
            _ = try db.upsertNode(label: node.label, id: node.id, properties: properties)
        }
        let reopened = try await MemoryStore.open(at: directory.database)
        await #expect(throws: NovaContextError.invalidStore) { try await reopened.memory(id: saved.id, in: "a") }
        await #expect(throws: NovaContextError.invalidStore) { try await reopened.remember(draft("Replacement", id: saved.id), in: "a") }
        try await reopened.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            #expect(try db.nodes(label: "NCMemory").first?.properties["text"] == .string(""))
        }
    }
}


extension MemoryStoreTests {
    @Test(arguments: [false, true])
    func ambiguousWriteIsNotRetriedAndCanBeReconciled(commitBeforeFailure: Bool) async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let failure = try ambiguousMutationError()
        let attempts = TestClock(0)
        let store = try await MemoryStore.open(at: directory.database, clock: { 500 }, mutation: { db, query, parameters, request in
            attempts.increment()
            if commitBeforeFailure { _ = try db.queryResult(query, parameters: parameters, request: request) }
            throw failure
        })
        let input = draft()
        await #expect(throws: failure) { try await store.remember(input, in: "a") }
        #expect(attempts.read() == 1)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        let recovered = try await reopened.memory(id: input.id, in: "a")
        #expect((recovered != nil) == commitBeforeFailure)
        if commitBeforeFailure { #expect(recovered?.text == input.text) }
        try await reopened.close()
    }

    @Test func mutationWithoutReceiptIsNeverAcknowledged() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database, clock: { 500 }, mutation: { db, _, _, request in
            try db.queryResult("get node 'nc:metadata'", request: request)
        })
        let input = draft()
        await #expect(throws: NovaContextError.invalidStore) { try await store.remember(input, in: "a") }
        #expect(try await store.memory(id: input.id, in: "a") == nil)
        try await store.close()
    }

    @Test func cancellationBeforeWriteLeavesNoMemory() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let input = draft()
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await store.remember(input, in: "a"); return false }
            catch let error as GraphCoreError { return error.code == "cancelled" }
            catch is CancellationError { return true }
            catch { Issue.record("Unexpected cancellation error: \(error)"); return false }
        }.value
        #expect(outcome)
        #expect(try await store.memory(id: input.id, in: "a") == nil)
        try await store.close()
    }

    @Test func aCommittedWriteIsReturnedDespiteLateCancellation() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database, clock: { 500 }, mutation: { db, query, parameters, request in
            let result = try db.queryResult(query, parameters: parameters, request: request)
            request.cancel()
            return result
        })
        let input = draft()
        let saved = try await store.remember(input, in: "a")
        #expect(try await store.memory(id: input.id, in: "a") == saved)
        try await store.close()
    }
}


extension MemoryStoreTests {
    @Test func overfullStoredScopeIsRejectedRatherThanReadAsAPartialSuccess() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        _ = try await store.remember(draft(), in: "a")
        try await store.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            let sample = try #require(try db.nodes(label: "NCMemory").first)
            let scope = try #require(try db.nodes(label: "NCScope").first)
            _ = try db.transactionReceipt { transaction in
                for _ in 0..<128 {
                    let id = UUID().uuidString.lowercased()
                    var properties = sample.properties
                    properties["memoryID"] = .string(id)
                    let key = "nc:scope:YQ:memory:\(id)"
                    transaction.upsertNode(label: "NCMemory", id: key, properties: properties)
                    transaction.upsertEdge(type: "NC_CONTAINS", from: scope.id, to: key)
                }
            }
        }
        let reopened = try await MemoryStore.open(at: directory.database)
        await #expect(throws: NovaContextError.invalidStore) { try await reopened.clear(scope: "a") }
        try await reopened.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            #expect(try db.nodes(label: "NCMemory", limit: 200).count == 129)
        }
    }

    @Test func wrongScopeMembershipNeverReturnsForeignContent() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let a = try await store.remember(draft("A"), in: "a")
        let b = try await store.remember(draft("B"), in: "b")
        try await store.close()
        try withRawDatabase(directory.database) { (db: GraphDatabase) throws in
            _ = try db.upsertEdge(type: "NC_CONTAINS", from: "nc:scope:YQ",
                                  to: "nc:scope:Yg:memory:\(b.id.uuidString.lowercased())")
        }
        let reopened = try await MemoryStore.open(at: directory.database)
        await #expect(throws: NovaContextError.invalidStore) { try await reopened.memory(id: a.id, in: "a") }
        #expect(try await reopened.memory(id: b.id, in: "b") == b)
        try await reopened.close()
    }

    @Test func canonicallyEquivalentUnicodeScopesRemainByteDistinct() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        let id = UUID()
        _ = try await store.remember(draft("Composed", id: id), in: composed)
        _ = try await store.remember(draft("Decomposed", id: id), in: decomposed)
        #expect(try await store.memory(id: id, in: composed)?.text == "Composed")
        #expect(try await store.memory(id: id, in: decomposed)?.text == "Decomposed")
        try await store.clear(scope: composed)
        #expect(try await store.memory(id: id, in: decomposed)?.text == "Decomposed")
        try await store.close()
    }

    @Test func cancelledCallerCanStillCloseAndReopen() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "a")
        try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.close()
        }.value
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: saved.id, in: "a") == saved)
        try await reopened.close()
    }
}
