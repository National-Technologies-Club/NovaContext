import Foundation

/// The application-defined role of a memory; no model inference is performed.
public enum MemoryKind: String, Codable, Sendable { case fact, message, toolResult }
/// Provenance is explicit. A model-produced record is not a user-confirmed fact.
public enum MemoryOrigin: String, Codable, Sendable { case user, application, model }

/// A complete replacement payload. Keep `id` when updating an existing memory.
public struct MemoryDraft: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var kind: MemoryKind
    public var origin: MemoryOrigin
    public var source: String?
    public var pinned: Bool

    public init(id: UUID = UUID(), text: String, kind: MemoryKind, origin: MemoryOrigin,
                source: String? = nil, pinned: Bool = false) {
        self.id = id
        self.text = text
        self.kind = kind
        self.origin = origin
        self.source = source
        self.pinned = pinned
    }
}

/// An acknowledged record with persisted application timestamps in Unix milliseconds.
public struct Memory: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let scope: String
    public let text: String
    public let kind: MemoryKind
    public let origin: MemoryOrigin
    public let source: String?
    public let pinned: Bool
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
}

/// NovaContext validation/lifecycle failures. Native storage errors propagate unchanged.
public enum NovaContextError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case scopeFull
    case unsupportedSchema(Int)
    case invalidStore
    case suspended
    case closed
    case tokenCounterRequired
    case invalidTokenCount
}
