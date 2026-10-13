import Foundation
import GraphDBKit

/// Accessed only by MemoryStore's serial queue. Never escapes a submitted operation.
final class NovaStorage {
    typealias MutationExecutor = @Sendable (GraphDatabase, String, [String: GraphValue], GraphRequest) throws -> GraphQueryResult

    static func executeMutation(_ db: GraphDatabase, _ program: String,
                                _ parameters: [String: GraphValue], _ request: GraphRequest) throws -> GraphQueryResult {
        try db.queryResult(program, parameters: parameters, request: request)
    }

    enum LifecycleAction: Sendable { case trim, suspend, resume }
    typealias LifecycleExecutor = @Sendable (GraphDatabase, LifecycleAction) async throws -> Void

    static func executeLifecycle(_ database: GraphDatabase, _ action: LifecycleAction) async throws {
        switch action {
        case .trim: _ = try await database.trimMemory(to: 0)
        case .suspend: try await database.suspend()
        case .resume: try await database.resume()
        }
    }

    let handle: GraphDatabase
    private let clock: @Sendable () -> Int64
    private let mutation: MutationExecutor

    init(directory: URL, clock: @escaping @Sendable () -> Int64, mutation: @escaping MutationExecutor, request: GraphRequest) throws {
        var configuration = GraphDatabaseConfiguration(path: directory)
        configuration.queryOptions.maxDepth = 1
        configuration.queryOptions.maxResults = 129
        configuration.queryOptions.maxExpandedEdges = 129
        handle = try GraphDatabase(configuration: configuration)
        self.clock = clock
        self.mutation = mutation
        do {
            try initializeSchema(request: request)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func initializeSchema(request: GraphRequest) throws {
        if let metadata = try node(id: "nc:metadata", request: request) {
            guard metadata.label == "NCMetadata",
                  let version = metadata.properties["schemaVersion"]?.intValue else {
                throw NovaContextError.invalidStore
            }
            guard version == 1 else { throw NovaContextError.unsupportedSchema(Int(version)) }
            return
        }
        struct Page: Decodable { let items: [GraphJSON] }
        for kind in [GraphInspectionKind.nodes, .edges, .indexes] {
            let page = try handle.inspect(kind, limit: 1, request: request).decode(as: Page.self)
            guard page.items.isEmpty else { throw NovaContextError.invalidStore }
        }
        _ = try handle.queryResult("upsert node NCMetadata 'nc:metadata' set schemaVersion=1", request: request)
    }

    func readScope(_ scope: String, request: GraphRequest) throws -> [Memory] {
        try Self.validateScope(scope)
        return try handle.readSnapshot(request: request) { snapshot in
            guard let scopeNode = try snapshot.node(id: Self.scopeKey(scope)) else { return [] }
            guard scopeNode.label == "NCScope", scopeNode.properties["scope"]?.stringValue?.utf8.elementsEqual(scope.utf8) == true else {
                throw NovaContextError.invalidStore
            }
            let nodes = try snapshot.queryResult(
                "walk from $scopeID over NC_CONTAINS direction out depth 1 limit 129",
                parameters: ["scopeID": .string(Self.scopeKey(scope))]
            ).nodes()
            guard nodes.count <= 128 else { throw NovaContextError.invalidStore }
            return try nodes.map { try decode($0, in: scope) }
        }
    }

    func remember(_ draft: MemoryDraft, in scope: String, request: GraphRequest) throws -> Memory {
        try Self.validate(draft)
        let memories = try readScope(scope, request: request)
        let existing = memories.first { $0.id == draft.id }
        guard existing != nil || memories.count < 128 else { throw NovaContextError.scopeFull }
        let now = clock()
        let memory = Memory(id: draft.id, scope: scope, text: draft.text, kind: draft.kind,
                            origin: draft.origin, source: draft.source, pinned: draft.pinned,
                            createdAtMs: existing?.createdAtMs ?? now, updatedAtMs: now)
        try commit("""
            upsert node NCScope $scopeID set scope=$scope;
            upsert node NCMemory $nodeID set memoryID=$memoryID, scope=$scope, text=$text,
                kind=$kind, origin=$origin, source=$source, pinned=$pinned,
                createdAtMs=$created, updatedAtMs=$updated;
            upsert edge NC_CONTAINS $scopeID -> $nodeID
            """, parameters: [
                "scopeID": .string(Self.scopeKey(scope)), "nodeID": .string(Self.memoryKey(draft.id, scope)),
                "memoryID": .string(draft.id.uuidString.lowercased()), "scope": .string(scope),
                "text": .string(draft.text), "kind": .string(draft.kind.rawValue),
                "origin": .string(draft.origin.rawValue), "source": draft.source.map(GraphValue.string) ?? .null,
                "pinned": .bool(draft.pinned), "created": .int(memory.createdAtMs), "updated": .int(now)
            ], request: request)
        return memory
    }

    func forget(id: UUID, in scope: String, request: GraphRequest) throws {
        guard try readScope(scope, request: request).contains(where: { $0.id == id }) else { return }
        try commit("delete node $id", parameters: ["id": .string(Self.memoryKey(id, scope))], request: request)
    }

    func clear(scope: String, request: GraphRequest) throws {
        let memories = try readScope(scope, request: request)
        guard try node(id: Self.scopeKey(scope), request: request) != nil else { return }
        var parameters: [String: GraphValue] = ["scopeID": .string(Self.scopeKey(scope))]
        var statements: [String] = []
        for (index, memory) in memories.enumerated() {
            let parameter = "id\(index)"
            parameters[parameter] = .string(Self.memoryKey(memory.id, scope))
            statements.append("delete node $\(parameter)")
        }
        statements.append("delete node $scopeID")
        try commit(statements.joined(separator: ";"), parameters: parameters, request: request)
    }

    func close() throws { try handle.close() }

    private func commit(_ program: String, parameters: [String: GraphValue], request: GraphRequest) throws {
        let result = try mutation(handle, program, parameters, request)
        guard result.receipt != nil else { throw NovaContextError.invalidStore }
        // A late cancellation must not replace an acknowledged or ambiguous commit outcome.
    }

    private static func validateScope(_ scope: String) throws {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              scope.utf8.count <= 128 else {
            throw NovaContextError.invalidArgument("Scope must be nonblank and at most 128 UTF-8 bytes.")
        }
    }

    private static func validate(_ draft: MemoryDraft) throws {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.text.utf8.count <= 4_096 else {
            throw NovaContextError.invalidArgument("Text must be nonblank and at most 4,096 UTF-8 bytes.")
        }
        guard (draft.source?.utf8.count ?? 0) <= 512 else {
            throw NovaContextError.invalidArgument("Source must be at most 512 UTF-8 bytes.")
        }
    }

    private func node(id: String, request: GraphRequest) throws -> Node? {
        do { return try handle.queryResult("get node $id", parameters: ["id": .string(id)], request: request).node() }
        catch let error as GraphCoreError where error.code == "notFound" { return nil }
    }

    private func decode(_ node: Node, in scope: String) throws -> Memory {
        let p = node.properties
        guard node.label == "NCMemory", p["scope"]?.stringValue?.utf8.elementsEqual(scope.utf8) == true,
              let rawID = p["memoryID"]?.stringValue, let id = UUID(uuidString: rawID),
              node.id == Self.memoryKey(id, scope),
              let text = p["text"]?.stringValue, let rawKind = p["kind"]?.stringValue,
              let kind = MemoryKind(rawValue: rawKind), let rawOrigin = p["origin"]?.stringValue,
              let origin = MemoryOrigin(rawValue: rawOrigin), let pinned = p["pinned"]?.boolValue,
              let created = p["createdAtMs"]?.intValue, let updated = p["updatedAtMs"]?.intValue else {
            throw NovaContextError.invalidStore
        }
        let source: String?
        switch p["source"] {
        case .string(let value): source = value
        case .null: source = nil
        default: throw NovaContextError.invalidStore
        }
        do {
            try Self.validate(MemoryDraft(id: id, text: text, kind: kind, origin: origin, source: source, pinned: pinned))
        } catch { throw NovaContextError.invalidStore }
        return Memory(id: id, scope: scope, text: text, kind: kind, origin: origin, source: source,
                      pinned: pinned, createdAtMs: created, updatedAtMs: updated)
    }

    private static func scopeKey(_ scope: String) -> String {
        let encoded = Data(scope.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "nc:scope:\(encoded)"
    }

    private static func memoryKey(_ id: UUID, _ scope: String) -> String {
        "\(scopeKey(scope)):memory:\(id.uuidString.lowercased())"
    }
}
