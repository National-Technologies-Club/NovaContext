import Foundation
import FoundationModels
import Testing
import NovaContext
@testable import OnDeviceMemory

@MainActor private final class CapturingResponder: LocalResponder {
    var availability: ModelAvailability = .available
    var prompts: [String] = []
    var operation: (String) async throws -> String = { _ in "Use SQLite for the cache." }
    func respond(to prompt: String) async throws -> String {
        prompts.append(prompt)
        return try await operation(prompt)
    }
}

@MainActor private final class CapturingSession: ResponseSession {
    var prompts: [String] = []
    var failure: Error?
    func respond(to prompt: String) async throws -> String {
        prompts.append(prompt)
        if let failure { throw failure }
        return "Answer"
    }
}

private struct TemporaryMemory {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NovaContextDemo-\(UUID())")
    var database: URL { root.appendingPathComponent("memory.novacontext") }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor struct MemoryDemoTests {
    @Test func promptContainsOnlyCurrentScopedContextAndDoesNotSaveOutput() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let seed = try await MemoryStore.open(at: temp.database)
        _ = try await seed.remember(.init(text: "Foreign secret", kind: .fact, origin: .user), in: "other")
        try await seed.close()
        let responder = CapturingResponder()
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        demo.decision = "Use SQLite for the cache."
        await demo.rememberDecision()
        let selected = try #require(demo.context)
        #expect(selected.memories.map(\.text) == ["Use SQLite for the cache."])
        demo.question = "What should the cache use?"
        await demo.ask().value
        #expect(responder.prompts == ["Reference context:\n" + selected.text + "\n\nQuestion:\nWhat should the cache use?"])
        #expect(demo.answer == "Use SQLite for the cache.")
        #expect(!responder.prompts[0].contains("Foreign secret"))
        #expect(demo.context?.memories.count == 1)
        let id = try #require(demo.context?.memories.first?.id)
        await demo.forget(id)
        await demo.ask().value
        #expect(responder.prompts.last == "Reference context:\nNo stored memories selected.\n\nQuestion:\nWhat should the cache use?")
        await demo.close()
        let reopened = try await MemoryStore.open(at: temp.database)
        #expect(try await reopened.context(in: "project:demo").memories.isEmpty)
        #expect(try await reopened.context(in: "other").memories.count == 1)
        try await reopened.close()
    }

    @Test func unavailableModelLeavesMemoryActionsAvailable() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let responder = CapturingResponder()
        responder.availability = .unavailable("Enable Apple Intelligence")
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        #expect(demo.isReady && !demo.canAsk)
        demo.decision = "Still saved"
        await demo.rememberDecision()
        #expect(demo.context?.memories.first?.text == "Still saved")
        demo.question = "Question"
        await demo.ask().value
        #expect(responder.prompts.isEmpty && demo.modelError != nil)
        await demo.close()
    }

    @Test func questionsAreByteBoundedBeforeGeneration() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let responder = CapturingResponder()
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        for question in ["  ", String(repeating: "😀", count: 257), "!?😀"] {
            demo.question = question
            await demo.ask().value
            #expect(responder.prompts.isEmpty && demo.modelError != nil)
        }
        demo.question = "cache" + String(repeating: " ", count: 1_019)
        await demo.ask().value
        #expect(responder.prompts.count == 1 && demo.modelError == nil)
        await demo.close()
    }

    @Test func explicitAnswerSaveUsesModelProvenance() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let demo = MemoryDemo(directory: temp.database, responder: CapturingResponder())
        await demo.setActive(true).value
        demo.question = "Question"
        await demo.ask().value
        #expect(demo.context?.memories.isEmpty == true)
        await demo.saveAnswer()
        #expect(demo.memories.first?.origin == .model)
        #expect(demo.memories.first?.text == "Use SQLite for the cache.")
        #expect(demo.context?.memories.isEmpty == true)
        await demo.close()
    }

    @Test func cancellationStopsGenerationWithoutDeletingMemoryOrOverlappingRequests() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let responder = CapturingResponder()
        responder.operation = { _ in try await Task.sleep(for: .seconds(3)); return "Too late" }
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        demo.decision = "Keep this"
        await demo.rememberDecision()
        demo.question = "Question"
        let first = demo.ask()
        let deadline = ContinuousClock.now + .seconds(3)
        while responder.prompts.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(demo.isGenerating && !demo.canAsk)
        await demo.ask().value
        demo.cancelGeneration()
        await first.value
        #expect(responder.prompts.count == 1 && demo.answer.isEmpty && !demo.isGenerating)
        await demo.trim()
        #expect(demo.memories.first?.text == "Keep this")
        await demo.setActive(false).value
        #expect(!demo.isReady)
        await demo.setActive(true).value
        #expect(demo.memories.first?.text == "Keep this")
        await demo.close()
    }

    @Test func productionResponderCreatesFreshSessionsAndSeparatesInstructions() async throws {
        var sessions: [CapturingSession] = []
        var instructions: [String] = []
        let responder = AppleResponder(availability: { .available }, makeSession: { text in
            instructions.append(text)
            let session = CapturingSession()
            sessions.append(session)
            return session
        })
        #expect(try await responder.respond(to: "First reference and question") == "Answer")
        #expect(try await responder.respond(to: "Second reference and question") == "Answer")
        #expect(sessions.count == 2 && sessions[0] !== sessions[1])
        #expect(sessions[0].prompts == ["First reference and question"])
        #expect(sessions[1].prompts == ["Second reference and question"])
        #expect(instructions.count == 2 && instructions.allSatisfy { !$0.contains("First reference") && !$0.contains("Second reference") })
    }

    @Test func contextWindowFailureIsOneAttemptWithNoRetry() async throws {
        let session = CapturingSession()
        session.failure = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "Test"))
        var creations = 0
        let responder = AppleResponder(availability: { .available }, makeSession: { _ in creations += 1; return session })
        await #expect(throws: DemoError.contextWindow) { try await responder.respond(to: "Too large") }
        #expect(creations == 1 && session.prompts == ["Too large"])
    }
}

@MainActor extension MemoryDemoTests {
    @Test func oversizedOmittedMemoryCanStillBeCleared() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let demo = MemoryDemo(directory: temp.database, responder: CapturingResponder())
        await demo.setActive(true).value
        demo.decision = String(repeating: "x", count: 3_000)
        await demo.rememberDecision()
        #expect(demo.context?.memories.isEmpty == true && demo.context?.omittedCount == 1)
        await demo.clearProject()
        #expect(demo.context?.omittedCount == 0)
        await demo.close()
        let reopened = try await MemoryStore.open(at: temp.database)
        #expect(try await reopened.context(in: "project:demo").memories.isEmpty)
        try await reopened.close()
    }

    @Test func rapidSceneTransitionsPreserveBoundedContext() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let demo = MemoryDemo(directory: temp.database, responder: CapturingResponder())
        await demo.setActive(true).value
        for i in 1...5 {
            demo.decision = "Decision \(i)"
            await demo.rememberDecision()
        }
        let before = try #require(demo.context)
        #expect(before.memories.count == 4 && before.omittedCount == 1 && before.utf8Bytes <= 2_048)
        let background = demo.setActive(false)
        let foreground = demo.setActive(true)
        await background.value
        await foreground.value
        #expect(demo.isReady && demo.context == before && demo.memoryError == nil)
        await demo.close()
    }
}

@MainActor extension MemoryDemoTests {
    @Test func modelAvailabilityCanRecoverWithoutLeavingTheScreen() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let responder = CapturingResponder()
        responder.availability = .unavailable("Preparing model")
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        demo.question = "What should the cache use?"
        #expect(!demo.canAsk)
        responder.availability = .available
        demo.checkModelAvailability()
        #expect(demo.canAsk)
        #expect(responder.prompts.isEmpty)
        await demo.ask().value
        #expect(responder.prompts.count == 1 && !demo.answer.isEmpty)
        await demo.close()
    }
}

@MainActor extension MemoryDemoTests {
    @Test func controlsReachMemoriesOmittedFromPreview() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let seed = try await MemoryStore.open(at: temp.database)
        let saved = try await seed.remember(.init(text: String(repeating: "x", count: 3_000),
            kind: .toolResult, origin: .model, source: "Explicitly saved tool result"), in: MemoryDemo.scope)
        try await seed.close()
        let responder = CapturingResponder()
        responder.availability = .unavailable("No model")
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        #expect(demo.canEdit && !demo.canAsk)
        #expect(demo.memories == [saved])
        #expect(demo.context?.memories.isEmpty == true && demo.context?.omittedCount == 1)
        await demo.updateMemory(saved.id, text: "Use SQLite for cache")
        await demo.updateMemory(saved.id, pinned: true)
        let edited = try #require(demo.memories.first)
        #expect(edited.id == saved.id && edited.createdAtMs == saved.createdAtMs)
        #expect(edited.kind == .toolResult && edited.origin == .model && edited.source == saved.source)
        #expect(edited.text == "Use SQLite for cache" && edited.pinned)
        #expect(demo.context?.memories == [edited] && demo.contextQuestion == nil)
        await demo.close()
        await demo.setActive(true).value
        #expect(demo.memories == [edited])
        await demo.updateMemory(saved.id, pinned: false)
        #expect(demo.memories.first?.pinned == false)
        await demo.forget(saved.id)
        #expect(demo.memories.isEmpty && demo.context?.omittedCount == 0)
        #expect(responder.prompts.isEmpty && demo.memoryError == nil)
        await demo.close()
        let reopened = try await MemoryStore.open(at: temp.database)
        #expect(try await reopened.memories(in: MemoryDemo.scope).isEmpty)
        try await reopened.close()
    }

    @Test func missingEditedRecordIsNotResurrected() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let demo = MemoryDemo(directory: temp.database, responder: CapturingResponder())
        await demo.setActive(true).value
        demo.decision = "Original text"
        await demo.rememberDecision()
        let editing = try #require(demo.memories.first)
        await demo.forget(editing.id)
        await demo.updateMemory(editing.id, text: "Stale editor content")
        #expect(demo.memories.isEmpty && demo.context?.omittedCount == 0)
        #expect(demo.memoryError != nil)
        await demo.close()
        let reopened = try await MemoryStore.open(at: temp.database)
        #expect(try await reopened.memory(id: editing.id, in: MemoryDemo.scope) == nil)
        try await reopened.close()
    }

    @Test func questionAndPromptStayAssociated() async throws {
        let temp = TemporaryMemory()
        defer { temp.remove() }
        let seed = try await MemoryStore.open(at: temp.database)
        let relevant = try await seed.remember(.init(text: "Use SQLite for cache", kind: .fact,
            origin: .user), in: MemoryDemo.scope)
        for i in 1...4 {
            _ = try await seed.remember(.init(text: "Unrelated decision \(i)", kind: .fact,
                origin: .user, pinned: true), in: MemoryDemo.scope)
        }
        _ = try await seed.remember(.init(text: "Foreign cache sqlite secret", kind: .fact,
            origin: .user), in: "foreign")
        try await seed.close()
        let responder = CapturingResponder()
        var pending: CheckedContinuation<String, Never>?
        responder.operation = { _ in await withCheckedContinuation { pending = $0 } }
        defer { pending?.resume(returning: "Cleanup") }
        let demo = MemoryDemo(directory: temp.database, responder: responder)
        await demo.setActive(true).value
        #expect(demo.memories.count == 5 && demo.context?.memories.count == 4)
        #expect(demo.context?.memories.contains { $0.id == relevant.id } == false)
        #expect(demo.contextQuestion == nil)
        demo.question = "cache sqlite"
        let generation = demo.ask()
        let deadline = ContinuousClock.now + .seconds(3)
        while responder.prompts.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        try #require(responder.prompts.count == 1)
        let selected = try #require(demo.context)
        #expect(selected.memories.map(\.id) == [relevant.id])
        #expect(selected.omittedCount == 4 && selected.utf8Bytes <= 2_048)
        #expect(responder.prompts[0] == "Reference context:\n" + selected.text + "\n\nQuestion:\ncache sqlite")
        #expect(!responder.prompts[0].contains("Foreign") && !responder.prompts[0].contains("Unrelated"))
        demo.question = "Different input"
        #expect(demo.contextQuestion == "cache sqlite")
        pending?.resume(returning: "SQLite answer")
        pending = nil
        await generation.value
        #expect(demo.answer == "SQLite answer" && demo.answerQuestion == "cache sqlite")
        #expect(demo.contextQuestion == "cache sqlite" && demo.question == "Different input")
        // Refresh after editing retains the submitted query, not the text field's new value.
        await demo.updateMemory(relevant.id, text: "Use PostgreSQL for storage")
        #expect(demo.answer.isEmpty && demo.answerQuestion == nil)
        #expect(demo.context?.memories.isEmpty == true && demo.context?.omittedCount == 5)
        #expect(demo.contextQuestion == "cache sqlite")
        responder.operation = { _ in "PostgreSQL answer" }
        demo.question = "PostgreSQL"
        await demo.ask().value
        #expect(demo.context?.memories.map(\.id) == [relevant.id] && !demo.answer.isEmpty)
        await demo.updateMemory(relevant.id, pinned: true)
        #expect(demo.answer.isEmpty && demo.answerQuestion == nil)
        await demo.ask().value
        #expect(!demo.answer.isEmpty)
        await demo.forget(relevant.id)
        #expect(demo.answer.isEmpty && demo.context?.memories.isEmpty == true)
        await demo.ask().value
        #expect(responder.prompts.last == "Reference context:\nNo stored memories selected.\n\nQuestion:\nPostgreSQL")
        #expect(demo.contextQuestion == "PostgreSQL" && demo.answerQuestion == "PostgreSQL")
        await demo.close()
    }
}
