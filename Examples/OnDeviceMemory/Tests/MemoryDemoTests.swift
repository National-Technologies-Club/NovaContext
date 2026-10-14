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
        for question in ["  ", String(repeating: "😀", count: 257)] {
            demo.question = question
            await demo.ask().value
            #expect(responder.prompts.isEmpty && demo.modelError != nil)
        }
        demo.question = String(repeating: "😀", count: 256)
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
        #expect(demo.context?.memories.first?.origin == .model)
        #expect(demo.context?.memories.first?.text == "Use SQLite for the cache.")
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
        #expect(demo.context?.memories.first?.text == "Keep this")
        await demo.setActive(false).value
        #expect(!demo.isReady)
        await demo.setActive(true).value
        #expect(demo.context?.memories.first?.text == "Keep this")
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
