import Foundation
import Observation
import SwiftUI
import NovaContext

@MainActor @Observable final class MemoryDemo {
    static let scope = "project:demo"
    private static let contextBudget = ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048)
    var decision = ""
    var question = ""
    private(set) var memories: [Memory] = []
    private(set) var contextQuestion: String?
    private(set) var answerQuestion: String?
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
            invalidateAnswer()
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
            invalidateAnswer()
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
            invalidateAnswer()
            try await refresh(from: store)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
    }

    func updateMemory(_ id: UUID, text: String? = nil, pinned: Bool? = nil) async {
        guard canEdit, let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try await store.update(id: id, in: Self.scope, text: text, pinned: pinned)
            invalidateAnswer()
            try await refresh(from: store)
            memoryError = updated == nil ? "This memory no longer exists. The list has been refreshed." : nil
        } catch { memoryError = error.localizedDescription }
    }

    func clearProject() async {
        guard canEdit, let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.clear(scope: Self.scope)
            invalidateAnswer()
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
        invalidateAnswer()
        context = nil
        let task = Task {
            defer { isGenerating = false }
            do {
                let selected = try await store.recall(question, in: Self.scope, budget: Self.contextBudget)
                try Task.checkCancellation()
                context = selected
                contextQuestion = question
                let reference = selected.text.isEmpty ? "No stored memories selected." : selected.text
                let prompt = "Reference context:\n" + reference + "\n\nQuestion:\n" + question
                let response = try await responder.respond(to: prompt)
                try Task.checkCancellation()
                answer = response
                answerQuestion = question
            } catch {
                modelError = Task.isCancelled ? "Generation cancelled. Stored memories are unchanged." : error.localizedDescription
            }
        }
        generationTask = task
        return task
    }

    func checkModelAvailability() { availability = responder.availability }

    func cancelGeneration() { generationTask?.cancel() }

    private func invalidateAnswer() {
        answer = ""
        answerQuestion = nil
        modelError = nil
    }

    private func refresh(from store: MemoryStore) async throws {
        do {
            let all = try await store.memories(in: Self.scope)
            let selected: ContextPayload
            if let query = contextQuestion {
                selected = try await store.recall(query, in: Self.scope, budget: Self.contextBudget)
            } else {
                selected = try await store.context(in: Self.scope, budget: Self.contextBudget)
            }
            if context != selected { invalidateAnswer() }
            memories = all
            context = selected
        } catch {
            // A failed refresh must not present old data or answers as the current state.
            memories = []
            context = nil
            invalidateAnswer()
            throw error
        }
    }
}

struct MemoryDemoView: View {
    @State var model: MemoryDemo
    @State private var confirmsClear = false
    @State private var editingMemory: Memory?
    let modelFree: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(modelFree ? "Model-free preview" : "On-device memory", systemImage: "brain")
                    Text("Manage saved memories, then ask a question to select matching context.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if case .unavailable(let reason) = model.availability {
                        Text(reason).foregroundStyle(.secondary)
                        Button("Check model availability") { model.checkModelAvailability() }
                            .accessibilityIdentifier("check-model-availability")
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
                Section("Stored memories") {
                    ForEach(model.memories) { memory in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(memory.text).lineLimit(4)
                            Text("\(memory.kind.rawValue) · \(memory.origin.rawValue)\(memory.pinned ? " · pinned" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let source = memory.source {
                                Text(source).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Edit") { editingMemory = memory }
                                    .accessibilityIdentifier("edit-\(memory.id)")
                                Button(memory.pinned ? "Unpin" : "Pin") {
                                    Task { await model.updateMemory(memory.id, pinned: !memory.pinned) }
                                }
                                Spacer()
                                Button("Forget", role: .destructive) { Task { await model.forget(memory.id) } }
                            }
                            .buttonStyle(.borderless).disabled(!model.canEdit)
                        }
                    }
                    Text("\(model.memories.count) stored in this project. Context limits do not hide records from this list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(model.contextQuestion == nil ? "Recent / pinned preview" : "Context for submitted question") {
                    if let context = model.context {
                        if let query = model.contextQuestion {
                            Text("Question: \(query)").accessibilityIdentifier("context-question")
                        } else {
                            Text("Preview only. Submit a question to select matching memories.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(context.memories.count) selected · \(context.omittedCount) omitted · \(context.utf8Bytes) bytes")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(model.contextQuestion == nil ? "Exact preview context" : "Exact reference context") {
                            Text(context.text.isEmpty ? "No stored memories selected." : context.text)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    } else { Text("No context preview available.").foregroundStyle(.secondary) }
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
                        if let question = model.answerQuestion {
                            Text("Answer to: \(question)").font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("answer-question")
                        }
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
                    Text("4 records · 2 KiB context · 1 KiB question with a searchable term. These are byte limits, not a model token-window guarantee.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NovaContext")
            .sheet(item: $editingMemory) { memory in
                MemoryEditorView(model: model, memory: memory)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { model.setActive(true) }
                if phase == .background { model.setActive(false) }
            }
        }
    }
}

private struct MemoryEditorView: View {
    let model: MemoryDemo
    let memory: Memory
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(model: MemoryDemo, memory: Memory) {
        self.model = model
        self.memory = memory
        _text = State(initialValue: memory.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory text") {
                    TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("memory-editor")
                    Text("\(memory.kind.rawValue) · \(memory.origin.rawValue)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let source = memory.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                }
                if let error = model.memoryError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.updateMemory(memory.id, text: text)
                            if model.memoryError == nil { dismiss() }
                        }
                    }.disabled(!model.canEdit)
                }
            }
            .interactiveDismissDisabled(model.isWorking)
        }
    }
}
