import Foundation
import Testing
import GraphDBKit
@testable import NovaContext

struct TestDirectory {
    let root: URL
    let database: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NovaContextTests-\(UUID())", isDirectory: true)
        database = root.appendingPathComponent("memory.novacontext", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

// Test-only clock; all reads/writes are protected while tests and storage use different queues.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func read() -> Int64 { lock.withLock { value } }
    func set(_ value: Int64) { lock.withLock { self.value = value } }
    func increment() { lock.withLock { value += 1 } }
}

func draft(_ text: String = "A remembered decision", id: UUID = UUID()) -> MemoryDraft {
    MemoryDraft(id: id, text: text, kind: .fact, origin: .user)
}

func withRawDatabase(_ url: URL, _ body: (GraphDatabase) throws -> Void) throws {
    let db = try GraphDatabase(path: url)
    defer { try? db.close() }
    try body(db)
}

func expectInvalidArgument(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected invalidArgument")
    } catch NovaContextError.invalidArgument {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}


func ambiguousMutationError() throws -> GraphCoreError {
    try JSONDecoder().decode(GraphCoreError.self, from: Data("""
        {"code":"commitOutcomeUnknown","message":"Injected ambiguous sync outcome",
         "context":{"file":"test.wal","osError":5,"object":"transaction",
         "transactionId":"test-transaction-id","statementIndex":1,"sourceStart":0,"sourceEnd":10}}
        """.utf8))
}
