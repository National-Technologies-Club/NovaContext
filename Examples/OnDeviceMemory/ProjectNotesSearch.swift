import Foundation
import FoundationModels
import NovaContext

enum ProjectNotesSearchError: Error, Equatable, LocalizedError {
    case invalidQuery, attemptLimitReached, resultTooLarge, inactive

    var errorDescription: String? {
        switch self {
        case .invalidQuery: "Enter a nonblank search query of at most 1,024 UTF-8 bytes."
        case .attemptLimitReached: "This question has used its two project-note searches."
        case .resultTooLarge: "The project-note search result exceeds its 2,048-byte allowance."
        case .inactive: "This project-note search request has ended."
        }
    }
}

struct ProjectNotesSearchCall: Sendable, Equatable, Identifiable {
    enum Status: Sendable, Equatable {
        case pending
        case succeeded(output: String, memoryIDs: [UUID])
        case failed(String)
        case discarded
    }

    let id: Int
    let query: String?
    fileprivate(set) var status: Status
}

/// One question's read-only capability. The host supplies the store/scope-bound reader.
/// Actor isolation protects admission; reads may overlap across suspension.
actor ProjectNotesSearch {
    private let read: @Sendable (String) async throws -> ContextPayload
    private var active = true
    private var calls: [ProjectNotesSearchCall] = []

    init(read: @escaping @Sendable (String) async throws -> ContextPayload) {
        self.read = read
    }

    func search(query: String) async throws -> String {
        try Task.checkCancellation()
        guard active else { throw ProjectNotesSearchError.inactive }
        guard calls.count < 2 else { throw ProjectNotesSearchError.attemptLimitReached }

        let index = calls.count
        let fits = query.utf8.count <= 1_024
        calls.append(.init(id: index + 1, query: fits ? query : nil, status: .pending))
        do {
            guard fits, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectNotesSearchError.invalidQuery
            }
            let result = try await read(query)
            try Task.checkCancellation()
            guard active else { throw ProjectNotesSearchError.inactive }
            let output = result.text.isEmpty ? "No matching project notes." : result.text
            guard output.utf8.count <= 2_048 else { throw ProjectNotesSearchError.resultTooLarge }
            calls[index].status = .succeeded(output: output, memoryIDs: result.memories.map(\.id))
            return output
        } catch {
            if active {
                if Task.isCancelled || error is CancellationError {
                    calls[index].status = .discarded
                } else {
                    // Retain a bounded display message, not arbitrary reader diagnostics/data.
                    let message = (error as? ProjectNotesSearchError)?.errorDescription
                        ?? "Project-note search failed."
                    calls[index].status = .failed(message)
                }
            }
            throw error
        }
    }

    /// Stops new admission without waiting for an uncooperative reader. Late completions
    /// cannot replace discarded records or mutate this returned value snapshot.
    func finish() -> [ProjectNotesSearchCall] {
        active = false
        for index in calls.indices where calls[index].status == .pending {
            calls[index].status = .discarded
        }
        return calls
    }
}

/// Registered by the sample's model adapter; it exposes a query, never a path or scope.
struct SearchProjectNotes: Tool {
    @Generable struct Arguments {
        @Guide(description: "Keywords to match in saved project notes.")
        var query: String
    }

    let search: ProjectNotesSearch
    let name = "search_project_notes"
    let description = "Search saved notes in this project using keywords."

    func call(arguments: Arguments) async throws -> String {
        try await search.search(query: arguments.query)
    }
}
