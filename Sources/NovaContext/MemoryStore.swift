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
                     mutation: @escaping NovaStorage.MutationExecutor = NovaStorage.executeMutation) async throws -> MemoryStore {
        let storage = StorageQueue()
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

/// The only unchecked boundary: all mutable state and NovaStorage access are confined
/// to `queue`. Every submitted closure retains this owner until its operation finishes.
private final class StorageQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NovaContext.storage", qos: .utility)
    var database: NovaStorage?
    var closeResult: Result<Void, Error>?

    func requireOpen() throws -> NovaStorage {
        guard closeResult == nil, let database else { throw NovaContextError.closed }
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

    deinit {
        // Retain the native handle until cleanup runs off the caller's thread.
        // No queued operation can still reference this owner when deinit begins.
        let handle = database?.handle
        queue.async { try? handle?.close() }
    }
}
