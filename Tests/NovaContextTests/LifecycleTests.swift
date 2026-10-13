import Foundation
import Testing
@testable import NovaContext

struct LifecycleTests {
    @Test func contentSurvivesTrimSuspendAndReopen() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let original = try await store.remember(draft("Remember this"), in: "project")
        let before = try await store.context(in: "project")
        try await store.trimMemory()
        #expect(try await store.context(in: "project") == before)
        try await store.suspend()
        try await store.suspend()
        try await store.resume()
        try await store.resume()
        #expect(try await store.context(in: "project") == before)
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: original.id, in: "project") == original)
        #expect(try await reopened.context(in: "project") == before)
        try await reopened.close()
    }

    @Test func suspendedStoreRejectsOrdinaryOperationsButAllowsClose() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let saved = try await store.remember(draft(), in: "project")
        try await store.suspend()
        await #expect(throws: NovaContextError.suspended) { try await store.memory(id: saved.id, in: "project") }
        await #expect(throws: NovaContextError.suspended) { try await store.context(in: "project") }
        await #expect(throws: NovaContextError.suspended) { try await store.remember(draft(), in: "project") }
        await #expect(throws: NovaContextError.suspended) { try await store.forget(id: saved.id, in: "project") }
        await #expect(throws: NovaContextError.suspended) { try await store.clear(scope: "project") }
        await #expect(throws: NovaContextError.suspended) { try await store.trimMemory() }
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.memory(id: saved.id, in: "project") == saved)
        try await reopened.close()
    }

    @Test func closedStoreRejectsAllLifecycleOperations() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        try await store.close()
        await #expect(throws: NovaContextError.closed) { try await store.trimMemory() }
        await #expect(throws: NovaContextError.closed) { try await store.suspend() }
        await #expect(throws: NovaContextError.closed) { try await store.resume() }
        try await store.close()
    }

    @Test func deletedAndReplacedRecordsStayChangedAcrossLifecycle() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let deleted = try await store.remember(draft("Deleted"), in: "project")
        let replaced = try await store.remember(draft("Old"), in: "project")
        try await store.forget(id: deleted.id, in: "project")
        let expected = try await store.remember(draft("Replacement", id: replaced.id), in: "project")
        try await store.trimMemory()
        try await store.suspend()
        try await store.resume()
        #expect(try await store.context(in: "project").memories == [expected])
        try await store.close()
        let reopened = try await MemoryStore.open(at: directory.database)
        #expect(try await reopened.context(in: "project").memories == [expected])
        try await reopened.close()
    }
}

private enum LifecycleFailure: Error { case checkpoint, resume }

private actor LifecycleSignal {
    private var signalled = false
    func signal() { signalled = true }
    func wait() async throws {
        // Bounded wait makes ordering failures report rather than hang the test run.
        let deadline = ContinuousClock.now + .seconds(3)
        while !signalled {
            guard ContinuousClock.now < deadline else { throw LifecycleFailure.checkpoint }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

extension LifecycleTests {
    @Test func failedSuspendIsRetainedUntilSuccessfulResume() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let resumes = TestClock(0)
        let store = try await MemoryStore.open(at: directory.database, clock: { 1 }, lifecycle: { db, action in
            switch action {
            case .suspend:
                try await db.suspend()
                throw LifecycleFailure.checkpoint
            case .resume:
                resumes.increment()
                if resumes.read() == 1 { throw LifecycleFailure.resume }
                try await db.resume()
            case .trim: _ = try await db.trimMemory(to: 0)
            }
        })
        let saved = try await store.remember(draft(), in: "project")
        await #expect(throws: LifecycleFailure.checkpoint) { try await store.suspend() }
        await #expect(throws: LifecycleFailure.checkpoint) { try await store.suspend() }
        await #expect(throws: LifecycleFailure.resume) { try await store.resume() }
        await #expect(throws: NovaContextError.suspended) { try await store.context(in: "project") }
        try await store.resume()
        #expect(try await store.context(in: "project").memories == [saved])
        try await store.close()
    }

    @Test func suspensionRetainsQueueOrderingAcrossAsyncWork() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let entered = LifecycleSignal()
        let release = LifecycleSignal()
        let store = try await MemoryStore.open(at: directory.database, clock: { 1 }, lifecycle: { db, action in
            if action == .suspend {
                await entered.signal()
                try await release.wait()
            }
            try await NovaStorage.executeLifecycle(db, action)
        })
        let saved = try await store.remember(draft(), in: "project")
        let suspension = Task { try await store.suspend() }
        try await entered.wait()
        let write = Task { try await store.remember(draft("Must not write"), in: "project") }
        await release.signal()
        try await suspension.value
        await #expect(throws: NovaContextError.suspended) { try await write.value }
        try await store.resume()
        #expect(try await store.context(in: "project").memories == [saved])
        try await store.close()
    }

    @Test func cancellationReachesAsyncLifecycleAndReleasesQueue() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let entered = LifecycleSignal()
        let store = try await MemoryStore.open(at: directory.database, clock: { 1 }, lifecycle: { db, action in
            if action == .suspend {
                await entered.signal()
                try await Task.sleep(for: .seconds(3))
                throw LifecycleFailure.checkpoint
            }
            try await NovaStorage.executeLifecycle(db, action)
        })
        let saved = try await store.remember(draft(), in: "project")
        let suspension = Task { try await store.suspend() }
        try await entered.wait()
        suspension.cancel()
        await #expect(throws: CancellationError.self) { try await suspension.value }
        await #expect(throws: NovaContextError.suspended) { try await store.context(in: "project") }
        try await store.resume()
        #expect(try await store.context(in: "project").memories == [saved])
        try await store.close()
    }

    @Test func alreadyCancelledLifecycleDoesNotSuspendStore() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let store = try await MemoryStore.open(at: directory.database)
        let suspension = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.suspend()
        }
        await #expect(throws: CancellationError.self) { try await suspension.value }
        #expect(try await store.context(in: "project").memories.isEmpty)
        try await store.close()
    }
}
