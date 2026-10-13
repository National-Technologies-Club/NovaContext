import Dispatch
import Foundation
import GraphDBKit

/// An exclusively owned database of scoped memories. Call `close()` before releasing it.
public final class MemoryStore: Sendable {
    private let storage: StorageQueue

    private init(storage: StorageQueue) { self.storage = storage }

    /// Opens a dedicated NovaContext directory, creating schema metadata when empty.
    public static func open(at directory: URL) async throws -> MemoryStore {
        try await open(at: directory, clock: { Int64(Date().timeIntervalSince1970 * 1_000) })
    }

    static func open(at directory: URL, clock: @escaping @Sendable () -> Int64,
                     mutation: @escaping NovaStorage.MutationExecutor = NovaStorage.executeMutation,
                     lifecycle: @escaping NovaStorage.LifecycleExecutor = NovaStorage.executeLifecycle) async throws -> MemoryStore {
        let storage = StorageQueue(lifecycle: lifecycle)
        return try await storage.perform { owner, request in
            owner.database = try NovaStorage(directory: directory, clock: clock, mutation: mutation, request: request)
            return MemoryStore(storage: owner)
        }
    }

    /// Replaces the complete record at this scope and ID, preserving its creation time.
    public func remember(_ draft: MemoryDraft, in scope: String) async throws -> Memory {
        try await storage.perform { owner, request in
            try owner.requireOpen().remember(draft, in: scope, request: request)
        }
    }

    /// Returns only the record in the requested scope, or nil if it does not exist.
    public func memory(id: UUID, in scope: String) async throws -> Memory? {
        try await storage.perform { owner, request in
            try owner.requireOpen().readScope(scope, request: request).first { $0.id == id }
        }
    }

    /// Removes a scoped record. A missing record is a successful no-op.
    public func forget(id: UUID, in scope: String) async throws {
        try await storage.perform { owner, request in
            try owner.requireOpen().forget(id: id, in: scope, request: request)
        }
    }

    /// Atomically removes this scope and its records. Other scopes are unaffected.
    public func clear(scope: String) async throws {
        try await storage.perform { owner, request in
            try owner.requireOpen().clear(scope: scope, request: request)
        }
    }

    /// Returns pinned/recent memories packed within the requested context limits.
    /// Reads one coherent scope snapshot, then releases storage before counting tokens.
    /// Pinned records rank first, followed by update time descending and UUID ascending.
    /// Records that do not fit are omitted whole; the result reports every omission.
    /// Subsequent writes are reflected on the next request. This method performs no writes.
    public func context(in scope: String, budget: ContextBudget = .init(),
                        tokenCounter: (any TokenCounter)? = nil) async throws -> ContextPayload {
        try Task.checkCancellation()
        try ContextBuilder.validate(budget, tokenCounter: tokenCounter)
        let memories = try await storage.perform { owner, request in
            try owner.requireOpen().readScope(scope, request: request)
        }
        // The snapshot and serial queue are released before caller-supplied tokenization.
        try Task.checkCancellation()
        return try ContextBuilder.build(memories: memories, budget: budget, tokenCounter: tokenCounter)
    }

    /// Evicts eligible cached records without deleting memories. Requires an active store.
    public func trimMemory() async throws { try await storage.performLifecycle(.trim) }

    /// Checkpoints and stops ordinary operations until resume succeeds. A failed attempt
    /// also blocks operations; repeated suspend retains its outcome until successful resume.
    public func suspend() async throws { try await storage.performLifecycle(.suspend) }

    /// Restores access after suspension. Failure leaves the store suspended; safe to retry.
    public func resume() async throws { try await storage.performLifecycle(.resume) }

    /// Drains earlier work and closes the handle. Repeated calls retain the same outcome.
    /// Cleanup runs even if the calling task is cancelled. Reopen with a new store instance.
    public func close() async throws {
        try await storage.perform { owner, _ in
            if let result = owner.closeResult { return try result.get() }
            let result = Result<Void, Error> {
                if let database = owner.database { try database.close() }
            }
            owner.closeResult = result
            owner.database = nil
            try result.get()
        }
    }
}

/// Queue confinement boundary: all mutable state and NovaStorage access are confined
/// to `queue`. Every submitted closure retains this owner until its operation finishes.
private final class StorageQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NovaContext.storage", qos: .utility)
    var database: NovaStorage?
    var closeResult: Result<Void, Error>?
    private var suspendResult: Result<Void, Error>?
    private let lifecycle: NovaStorage.LifecycleExecutor

    init(lifecycle: @escaping NovaStorage.LifecycleExecutor) { self.lifecycle = lifecycle }

    func requireOpen(allowSuspended: Bool = false) throws -> NovaStorage {
        guard closeResult == nil, let database else { throw NovaContextError.closed }
        if !allowSuspended && suspendResult != nil { throw NovaContextError.suspended }
        return database
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (StorageQueue, GraphRequest) throws -> T) async throws -> T {
        let request = try GraphRequest()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { request.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try operation(self, request) })
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    func performLifecycle(_ action: NovaStorage.LifecycleAction) async throws {
        let bridge = LifecycleBridge()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await perform { owner, _ in
                let handle = try owner.requireOpen(allowSuspended: action != .trim).handle
                try bridge.checkCancellation()
                switch action {
                case .suspend:
                    if let result = owner.suspendResult { return try result.get() }
                    let result = Result { try bridge.run { try await owner.lifecycle(handle, action) } }
                    owner.suspendResult = result
                    try result.get()
                case .resume:
                    guard owner.suspendResult != nil else { return }
                    try bridge.run { try await owner.lifecycle(handle, action) }
                    owner.suspendResult = nil
                case .trim:
                    try bridge.run { try await owner.lifecycle(handle, action) }
                }
            }
        } onCancel: { bridge.cancel() }
    }

    deinit {
        // Retain the native handle until cleanup runs off the caller's thread.
        // No queued operation can still reference this owner when deinit begins.
        let handle = database?.handle
        queue.async { try? handle?.close() }
    }
}
