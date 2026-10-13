import Dispatch
import Foundation

/// Bridges Nova's async-only lifecycle APIs while retaining serial queue ordering.
/// Only the dedicated storage DispatchQueue may call run/wait, never a Swift task
/// or the main thread. All cross-thread state is protected by lock; cancel never waits.
final class LifecycleBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var result: Result<Void, Error>?

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func cancel() {
        let running = lock.withLock {
            cancelled = true
            return task
        }
        running?.cancel()
    }

    func run(_ operation: @escaping @Sendable () async throws -> Void) throws {
        let running = Task.detached(priority: .utility) {
            let outcome: Result<Void, Error>
            do {
                try self.checkCancellation()
                try Task.checkCancellation()
                try await operation()
                outcome = .success(())
            } catch { outcome = .failure(error) }
            self.lock.withLock {
                self.result = outcome
                self.task = nil
            }
            self.finished.signal()
        }
        let shouldCancel = lock.withLock {
            if result == nil { task = running }
            return cancelled
        }
        if shouldCancel { running.cancel() }
        finished.wait()
        // Preserve the underlying outcome, including completed storage work after
        // a late cancellation, rather than claiming a successful effect never happened.
        try lock.withLock { try result!.get() }
    }
}
