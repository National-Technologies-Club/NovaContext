import Foundation

/// Shared ordering for full lists, default context, and future relevance tie-breaks.
enum MemoryOrdering {
    static func precedes(_ left: Memory, _ right: Memory) -> Bool {
        if left.pinned != right.pinned { return left.pinned }
        if left.updatedAtMs != right.updatedAtMs { return left.updatedAtMs > right.updatedAtMs }
        return left.id.uuidString.lowercased() < right.id.uuidString.lowercased()
    }
}
