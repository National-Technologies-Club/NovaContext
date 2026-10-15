import Foundation

/// Derived search terms only; persisted text and provenance are never normalized.
enum KeywordRecall {
    static func terms(in query: String) throws -> Set<String> {
        try Task.checkCancellation()
        guard query.utf8.count <= 1_024 else {
            throw NovaContextError.invalidArgument("Recall queries must be at most 1,024 UTF-8 bytes.")
        }
        let terms = normalizedTerms(in: query)
        try Task.checkCancellation()
        guard !terms.isEmpty else {
            throw NovaContextError.invalidArgument("Recall queries must contain a letter or number.")
        }
        return terms
    }

    static func rank(_ memories: [Memory], terms: Set<String>) throws -> [Memory] {
        try Task.checkCancellation()
        var matches: [(memory: Memory, score: Int)] = []
        for memory in memories {
            try Task.checkCancellation()
            let score = terms.intersection(normalizedTerms(in: memory.text)).count
            if score > 0 { matches.append((memory, score)) }
        }
        let ranked = matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return MemoryOrdering.precedes($0.memory, $1.memory)
        }.map(\.memory)
        try Task.checkCancellation()
        return ranked
    }

    private static func normalizedTerms(in text: String) -> Set<String> {
        let normalized = text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        var terms: Set<String> = []
        var run = ""
        var hasLetterOrNumber = false
        for scalar in normalized.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                run.unicodeScalars.append(scalar)
                hasLetterOrNumber = true
            case .nonspacingMark, .spacingMark, .enclosingMark:
                run.unicodeScalars.append(scalar)
            default:
                if hasLetterOrNumber { terms.insert(run) }
                run = ""
                hasLetterOrNumber = false
            }
        }
        if hasLetterOrNumber { terms.insert(run) }
        return terms
    }
}
