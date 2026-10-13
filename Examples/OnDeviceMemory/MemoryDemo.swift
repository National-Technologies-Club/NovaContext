import Foundation
import Observation
import SwiftUI
import NovaContext

@MainActor @Observable final class MemoryDemo {
    static let scope = "project:demo"
    var decision = ""
    var question = ""
    private(set) var context: ContextPayload?
    private(set) var answer = ""
    private(set) var memoryError: String?
    private(set) var modelError: String?
    private(set) var availability: ModelAvailability
    private(set) var isGenerating = false
    private(set) var isWorking = false
    private(set) var isReady = false
    var canAsk: Bool { isReady && !isWorking && !isGenerating && availability == .available }
    var canEdit: Bool { isReady && !isWorking && !isGenerating }
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let responder: any LocalResponder
    @ObservationIgnored private var store: MemoryStore?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var wantsActive = false

    init(directory: URL, responder: any LocalResponder) {
        self.directory = directory
        self.responder = responder
        self.availability = responder.availability
    }

    /// Scene changes are chained: a fast foreground event cannot overtake suspension.
    @discardableResult func setActive(_ active: Bool) -> Task<Void, Never> {
        wantsActive = active
        isReady = false
        if !active { cancelGeneration() }
        let previous = lifecycleTask
        let next = Task {
            await previous?.value
            do {
                if active {
                    if store == nil { store = try await MemoryStore.open(at: directory) }
                    guard let store else { return }
                    try await store.resume()
                    availability = responder.availability
                    try await refresh(from: store)
                    memoryError = nil
                    isReady = wantsActive
                } else if let store {
                    try await store.suspend()
                }
            } catch { memoryError = error.localizedDescription }
        }
        lifecycleTask = next
        return next
    }

    func rememberDecision() async {
        guard canEdit, let store else { return }
        isWorking = true
        defer { isWorking = false }
        let text = decision
        do {
            _ = try await store.remember(.init(text: text, kind: .fact, origin: .user), in: Self.scope)
            if decision == text { decision = "" }
            try await refresh(from: store)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
    }

    func saveAnswer() async {
        guard canEdit, let store, !answer.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await store.remember(.init(text: answer, kind: .message, origin: .model,
                                               source: "Explicitly saved model response"), in: Self.scope)
            try await refresh(from: store)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
    }

    func forget(_ id: UUID) async {
        guard canEdit, let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.forget(id: id, in: Self.scope)
            // A displayed answer may reference the forgotten memory; do not present it as current.
            answer = ""
            try await refresh(from: store)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
    }

    func clearProject() async {
        guard canEdit, let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.clear(scope: Self.scope)
            answer = ""
            try await refresh(from: store)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
    }

    func trim() async {
        guard canEdit, let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.trimMemory()
            try await refresh(from: store)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
    }

    func close() async {
        wantsActive = false
        isReady = false
        cancelGeneration()
        let previous = lifecycleTask
        let next = Task {
            await previous?.value
            do {
                try await store?.close()
                store = nil
                memoryError = nil
            } catch { memoryError = error.localizedDescription }
        }
        lifecycleTask = next
        await next.value
    }

    @discardableResult func ask() -> Task<Void, Never> {
        guard !isGenerating else { return Task {} }
        guard canAsk, let store else {
            modelError = DemoError.unavailable.localizedDescription
            return Task {}
        }
        let question = question
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 1_024 else {
            modelError = DemoError.invalidQuestion.localizedDescription
            return Task {}
        }
        isGenerating = true
        answer = ""
        modelError = nil
        let task = Task {
            defer { isGenerating = false }
            do {
                let selected = try await store.context(in: Self.scope,
                    budget: ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048))
                try Task.checkCancellation()
                context = selected
                let reference = selected.text.isEmpty ? "No stored memories selected." : selected.text
                let prompt = "Reference context:\n" + reference + "\n\nQuestion:\n" + question
                let response = try await responder.respond(to: prompt)
                try Task.checkCancellation()
                answer = response
            } catch {
                modelError = Task.isCancelled ? "Generation cancelled. Stored memories are unchanged." : error.localizedDescription
            }
        }
        generationTask = task
        return task
    }

    func cancelGeneration() { generationTask?.cancel() }

    private func refresh(from store: MemoryStore) async throws {
        context = try await store.context(in: Self.scope,
            budget: ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048))
    }
}

struct MemoryDemoView: View {
    @State var model: MemoryDemo
    @State private var confirmsClear = false
    let modelFree: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(modelFree ? "Model-free preview" : "On-device memory", systemImage: "brain")
                    Text("Save a project decision, inspect the selected context, then ask a question.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if case .unavailable(let reason) = model.availability {
                        Text(reason).foregroundStyle(.secondary)
                    }
                    if let error = model.memoryError { Text(error).foregroundStyle(.red) }
                }
                Section("Remember a decision") {
                    TextField("e.g. Use SQLite for the cache", text: $model.decision, axis: .vertical)
                        .accessibilityIdentifier("decision")
                    Button("Remember") { Task { await model.rememberDecision() } }
                        .disabled(!model.canEdit)
                        .accessibilityIdentifier("remember")
                }
                Section("Selected memories") {
                    if let context = model.context {
                        ForEach(context.memories) { memory in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(memory.text)
                                HStack {
                                    Text(memory.origin.rawValue).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Forget", role: .destructive) { Task { await model.forget(memory.id) } }
                                        .buttonStyle(.borderless).disabled(!model.canEdit)
                                }
                            }
                        }
                        Text("\(context.memories.count) selected · \(context.omittedCount) omitted · \(context.utf8Bytes) bytes")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Exact context sent to the model") {
                            Text(context.text.isEmpty ? "No stored memories selected." : context.text)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    } else { Text("Open the store to load context.").foregroundStyle(.secondary) }
                }
                Section("Ask about your project") {
                    TextField("What should the cache use?", text: $model.question, axis: .vertical)
                        .accessibilityIdentifier("question")
                    if model.isGenerating {
                        HStack { ProgressView(); Button("Cancel") { model.cancelGeneration() } }
                    } else {
                        Button("Ask") { model.ask() }.disabled(!model.canAsk).accessibilityIdentifier("ask")
                    }
                    if let error = model.modelError { Text(error).foregroundStyle(.red) }
                    if !model.answer.isEmpty {
                        Text(model.answer).textSelection(.enabled).accessibilityIdentifier("answer")
                        if !modelFree {
                            Button("Save answer as model memory") { Task { await model.saveAnswer() } }
                                .disabled(!model.canEdit)
                        }
                    }
                }
                Section("Storage") {
                    Button("Trim cached memory") { Task { await model.trim() } }.disabled(!model.canEdit)
                    if model.isReady {
                        Button("Close store") { Task { await model.close() } }.disabled(model.isWorking)
                    } else {
                        Button("Open / resume store") { model.setActive(true) }
                    }
                    Button("Clear project memories", role: .destructive) { confirmsClear = true }
                        .disabled(!model.canEdit)
                        .confirmationDialog("Clear all project memories, including omitted records?", isPresented: $confirmsClear) {
                            Button("Clear project memories", role: .destructive) { Task { await model.clearProject() } }
                        }
                    Text("4 records · 2 KiB context · 1 KiB question. These are byte limits, not a model token-window guarantee.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NovaContext")
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { model.setActive(true) }
                if phase == .background { model.setActive(false) }
            }
        }
    }
}
