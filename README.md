# NovaContext

Persistent, scoped memory for Swift applications, backed by [NovaGraph](https://github.com/rhindsntc/NovaGraph).

NovaContext provides durable memory storage and deterministic context assembly with explicit byte limits and optional model-specific token limits. Its composer can bound instructions, selected memories, explicit recent conversation and a question together. No model runtime or network service is required. A separate [on-device example](Examples/OnDeviceMemory/README.md) integrates Apple Foundation Models.

## Installation

The first **v0.1.0** release is being prepared. The intended repository is `rhindsntc/NovaContext`; its repository and tag are not published yet. Use a local package until publication is complete.

### Swift Package Manager

After the `v0.1.0` tag is published, add this versioned dependency:

```swift
.package(url: "https://github.com/rhindsntc/NovaContext.git", exact: "0.1.0")
```

In Xcode, use **File → Add Package Dependencies**, enter that repository URL and select version **0.1.0**. Add the library product to your application target:

```swift
.product(name: "NovaContext", package: "novacontext")
```

### Local development

For now, add the NovaContext directory as a local Swift package in Xcode, or use a sibling package dependency:

```swift
.package(path: "../NovaContext")
```

The package uses Swift tools 6.0 and pins `GraphDBKit` from NovaGraph **1.0.0**. Declared deployment floors are iOS 16 and macOS 13. The separate Foundation Models sample requires Xcode 26+ and iOS 26+. See [compatibility and validation](Guides/Compatibility.md) for tested configurations and the pending physical-device checks.

## Remember explicit memories

Use a dedicated directory in your application's Application Support location. The SDK creates the database at that path; one store/process owns it at a time.

```swift
import Foundation
import NovaContext

func rememberDecision(at directory: URL) async throws {
    let store = try await MemoryStore.open(at: directory)
    do {
        let input = MemoryDraft(
            text: "Keep project data on device.",
            kind: .fact,
            origin: .user,
            source: "Project decision",
            pinned: true
        )
        let saved = try await store.remember(input, in: "project:nova")
        let context = try await store.context(
            in: "project:nova",
            budget: ContextBudget(maxMemories: 8, maxUTF8Bytes: 4_096)
        )
        print(context.text) // Pass this reference block to your app's model.
        print("Saved memory:", saved.id, "Omitted:", context.omittedCount)
        try await store.close()
    } catch {
        try? await store.close()
        throw error
    }
}
```

Keep the draft's UUID if you need to update or reconcile that record. Reopening the same directory returns previously committed memories. `remember` with the same UUID and scope replaces the entire payload, preserves `createdAtMs`, and updates `updatedAtMs`. Omitting a previous source or pin clears it. The same UUID can independently exist in another scope.

## Inspect and edit memories

`memories(in:)` returns every stored memory in the exact scope, including records omitted from context by its byte, token or record budget. It returns a coherent list of up to 128 records, ordered by pinned first, `updatedAtMs` descending and canonical UUID ascending. A missing scope returns `[]`; storage or validation failures throw instead of returning a partial list.

This function takes an open store, lists its memories, edits the first record, pins it, then forgets it:

```swift
import NovaContext

func editPinAndForgetFirstMemory(in store: MemoryStore) async throws {
    let scope = "project:nova"
    let memories = try await store.memories(in: scope)
    guard let first = memories.first else { return }
    guard let edited = try await store.update(
        id: first.id, in: scope, text: "Keep project data on device."
    ) else { return } // Another operation may have forgotten it.
    _ = try await store.update(id: edited.id, in: scope, pinned: true)
    try await store.forget(id: edited.id, in: scope)
}
```

`update(id:in:text:pinned:)` atomically changes only the supplied text and/or pinned state. Nil leaves that field unchanged; other fields, including creation time and model provenance, are preserved. Missing records return nil without being recreated. Unchanged text bytes and pinning cause no write or timestamp change. See the [controls contract](Guides/Usage.md#inspect-and-edit-stored-memories) for validation and concurrent updates.

```swift
// Given an open store:
try await store.clear(scope: "project:nova")
```

Forgetting a missing record or clearing a missing scope succeeds. Deletion is durable. There is no automatic expiry, eviction, extraction, or revision history. An origin of `.model` records provenance; it does not certify the content as true.

## Build context

Given an open store, select the scope you want the model to use:

```swift
let context = try await store.context(
    in: "project:nova",
    budget: ContextBudget(maxMemories: 8, maxUTF8Bytes: 4_096)
)
print(context.text)         // Reference header + JSON, or an empty string
print(context.omittedCount)
```

Pinned memories rank first, followed by the most recently updated memories. UUID breaks ties consistently. Records that do not fit are skipped whole; later smaller records can still fit. Pinning never overrides a limit. Updates and deletions appear on the next context request.

The defaults are **12 memories within 8 KiB**. Bytes include the header, metadata, and JSON escaping. To enforce an additional memory-block token allowance, pass `maxTokens` and your model's synchronous `TokenCounter`; NovaContext does not guess tokens from character counts. Use the composer below to bound the combined input, and account for your model adapter's formatting and output allowance.

Read the [usage guide](Guides/Usage.md) for token integration, cancellation, empty-context behavior, and scope selection. Context assembly retrieves a coherent snapshot and releases the storage queue before tokenization.

## Recall matching memories

`recall(_:in:budget:tokenCounter:)` searches memory text in one exact scope and returns a `ContextPayload` using the same byte, record and optional token limits as `context`:

```swift
import NovaContext

func recallProjectContext(from store: MemoryStore, query: String) async throws -> ContextPayload {
    try await store.recall(
        query,
        in: "project:nova",
        budget: ContextBudget(maxMemories: 8, maxUTF8Bytes: 4_096)
    )
}
```

Queries must fit within **1,024 UTF-8 bytes before normalization** and contain at least one searchable term; invalid queries throw `.invalidArgument`. Matching uses whole Unicode letter/number/combining-mark terms with case folding and canonical normalization. For example, `cache` matches `CACHE` but not `cacheable` or `caches`; composed and decomposed `café` match, while unaccented `cafe` does not. Source metadata is not searched, and stored values are unchanged.

Memories matching any query term rank by the number of distinct terms matched, then by pinning, update time descending and canonical UUID ascending. Repeated words add no weight; an unrelated pinned memory is excluded. This is lexical matching without stemming, fuzzy/prefix matching or language-specific word segmentation.

No matches returns an empty payload. The app can explicitly call `context` if it wants recent/pinned context as a fallback; recall never does so automatically. `omittedCount` is every scoped record minus the selected records, including nonmatches and matches that exceed the budget. Matching order is retained while packing, oversized records are skipped whole, and pinning never overrides a limit. See the [recall contract](Guides/Usage.md#recall-matching-memories) for exact normalization and empty-result behavior.

## Compose a bounded request

Recall memories, compose the initial request, then hand its exact fields to your model adapter. The callback below is supplied by your application; NovaContext never invokes a model itself.

```swift
import NovaContext

func answerProjectQuestion(
    from store: MemoryStore,
    question: String,
    history: [ConversationTurn] = [], // oldest to newest
    respond: (ComposedInput) async throws -> String
) async throws -> String {
    let matches = try await store.recall(
        question, in: "project:nova",
        budget: ContextBudget(maxMemories: 4, maxUTF8Bytes: 2_048)
    )
    let request = try await ContextComposer.compose(
        instructions: "Use saved memories as reference data. Do not invent saved facts.",
        question: question,
        memories: matches,
        history: history,
        budget: CompositionBudget(maxUTF8Bytes: 4_096, maxHistoryTurns: 4)
    )
    return try await respond(request.input)
}
```

The adapter receives separate `input.instructions` and `input.prompt`; send those strings unchanged. The prompt contains reference data, optional JSON-quoted history and the question. The composer performs no retrieval or writes, does not capture conversation automatically, and works with the memories already selected by `context` or `recall`.

| Composition allowance | Default | Maximum |
| --- | ---: | ---: |
| Instructions + prompt UTF-8 bytes | 16,384 | 65,536 |
| Selected complete history turns | 4 | 32 |
| Whole-input tokens | No cap | Caller-supplied nonnegative `maxTokens` |
| Reserved tokens | 0 | At most `maxTokens` |

Instructions must fit 8,192 UTF-8 bytes; a nonblank question must fit 1,024 original bytes. Supply at most 32 complete user/assistant turns, each field nonblank and at most 4,096 UTF-8 bytes. The composer itself accepts a nonblank question without searchable terms; the example's recall call still applies its keyword-query rules.

Mandatory instructions/question and fixed headers must fit or composition throws `.requiredInputTooLarge`. It then tries whole memories in their supplied order, skipping oversized candidates, followed by a contiguous suffix of recent history. A rejected newer turn stops history selection; an older smaller turn cannot cross the gap. Nothing is truncated or summarized. Zero allowances are valid but can reject mandatory content.

Inspect `request.memoryContext` for the final selected memories and accumulated scoped omissions, `request.history` for selected turns, and `request.omittedHistoryTurnCount` for omitted turns. `request.utf8Bytes` includes both returned strings and all rendered metadata/escaping. The earlier recall payload's byte/token counts are not reused, and the composer cannot recover its omitted candidates.

For whole-input token limits, provide an asynchronous `RequestTokenCounter` implementing `func countTokens(in input: ComposedInput) async throws -> Int`. It receives every complete byte-fitting candidate, rather than separate section counts. Set `CompositionBudget(maxTokens: ..., reservedTokens: ...)`; reservation requires a cap and cannot exceed it. Missing counters and negative counts throw; counter errors propagate. Without a token cap no counter is called. The final whole-input `tokenCount` is separate from `memoryContext.tokenCount`, which is nil after composition.

The guarantee covers the exact returned input under your counter. Include provider framing, tools, schemas or native history in that counter if the adapter adds them, and do not send composed history a second time. Reservation is explicit headroom for output or other context; it does not bound future tool calls. The existing synchronous memory-block `TokenCounter` remains unchanged. See the [composer contract](Guides/Usage.md#compose-a-bounded-model-request) for exact rendering, validation and cancellation.

## On-device example and lifecycle

The [SwiftUI example](Examples/OnDeviceMemory/README.md) shows the full **Stored memories** list with **Edit**, an **Edit memory** sheet with **Save/Cancel**, **Pin/Unpin**, **Forget**, and visible origin/source. It starts with **Recent / pinned preview**, then captures each submitted question for scoped keyword recall and labels **Context for submitted question** and **Answer to:** with that question. **Composed input** exposes the separate initial instructions/prompt and their combined byte count, before native tool definitions and later exchanges. Editing the question field leaves the submitted request and labels intact; a successful memory change clears the old answer and refreshes/recomposes the current preview without generating again. A failed refresh clears old request data and tool results. No-match recall stays empty, with no automatic recent-memory fallback.

The sample keeps its four-record/2,048-byte reference context and 1,024-byte question limits, plus **4,096 initial composed-input bytes**; a question also needs a searchable letter/number term. It passes history `[]` and uses no token estimator.

Each fresh native session also registers the sample-only, read-only `search_project_notes(query:)` tool: at most two attempts per question, a 1,024-byte query and four records within 2,048 returned UTF-8 bytes per search. The host fixes the scope to `project:demo`. **Project-note searches** displays captured queries, selected IDs and exact returned text separately after generation ends; results are ephemeral and never saved automatically. Native tool definitions and later exchanges consume additional model context, so these byte bounds do not guarantee token-window fit. The core SDK adds no public tool API.

Memory controls work without an available model. Foundation Models requires iOS 26+, and the example includes a labelled model-free mode, fresh sessions, cancellation and explicit model-answer saves. The owner previously reported that the installed sample worked well; detailed physical-device/build information and memory/latency observations remain unrecorded. See [validation status](Guides/Compatibility.md#validation-status) and the [walkthrough](Examples/OnDeviceMemory/README.md#walk-through-it).

```swift
// Given an active store:
try await store.trimMemory() // Drop cached records, preserving saved memories
try await store.suspend()    // Checkpoint and pause access
try await store.resume()     // Allow reads and writes again
```

The host app forwards lifecycle events; the SDK imports neither SwiftUI nor UIKit. A suspended store rejects ordinary operations until resume succeeds. Suspension failures also require resume or close; errors remain observable. See the [lifecycle contract](Guides/Usage.md#lifecycle).

## Initial limits

| Item | Limit |
| --- | ---: |
| Memories per scope | 128 |
| Memory text | 4,096 UTF-8 bytes |
| Scope | 128 UTF-8 bytes |
| Optional source description | 512 UTF-8 bytes |
| Recall query, before normalization | 1,024 UTF-8 bytes |

Scope and text must contain something other than whitespace. Accepted strings are preserved without trimming or normalization. Scope identity is case-sensitive and based on the exact UTF-8 bytes. At capacity, a new record throws `NovaContextError.scopeFull`; replacement and deletion remain available. Applications manage total retained data across scopes.

Each operation reads and validates the bounded scope. Nova's query workspace, result, and deadline limits still apply and may reject an operation. These are not process-memory or latency guarantees.

## Concurrency, errors, and close

All storage operations run on a private serial storage queue, including the complete admission check and write. Scope creation, memory replacement, and its membership edge are one atomic Nova transaction. A successful write requires a durable mutation receipt.

Call `close()` explicitly to drain earlier queued operations and observe checkpoint/storage errors. Close runs even from a cancelled task. Its result is retained for repeated calls; a closed instance rejects further operations with `.closed`. Use `MemoryStore.open(at:)` to create a new instance when reopening. Dropping an unclosed store schedules best-effort background cleanup, which cannot report errors.

Reads and writes forward cooperative cancellation to Nova. A commit already completed is returned even if cancellation arrives late. Storage errors from `GraphDBKit`, including their transaction context, propagate unchanged.

If Nova reports **`commitOutcomeUnknown`**, the write may have committed. Preserve the draft UUID, scope, and the error's transaction ID; close/reopen and inspect the recovered record before deciding what to do. NovaContext does not automatically retry or claim exactly-once behavior. A matching record alone cannot distinguish an identical earlier write.

NovaContext initializes schema metadata only in an empty database. Unsupported schema versions, unrelated unmarked databases, and malformed records encountered while reading are rejected without resetting application data. Use the SDK's dedicated directory rather than adding its records to another graph database.

## Development

```sh
swift package resolve
swift build
swift test
swift build -c release
```

Tests use real temporary Nova databases for persistence, replacement, full scoped lists, targeted edits, deletion, scope isolation, concurrent capacity admission, UTF-8 validation, schema protection, and cancellation. Context and keyword-recall tests cover deterministic ranking, whole-term Unicode matching, complete rendered byte/token accounting, full-scope omissions, scope isolation, and storage access during tokenization. Composer tests cover combined input bounds, mandatory-content failure, memory priority, recent-history suffixes, reservations and cancellation during async counting. Lifecycle tests cover suspension, failed transitions, cancellation forwarding, queue ordering and data preservation. A small internal mutation seam verifies error/receipt handling, including both possible outcomes of an ambiguous write; it is not a simulated power-loss qualification of Nova.

A macOS [CI workflow](.github/workflows/ci.yml) runs the three build/test commands above for pushes and pull requests. Hosted checks cover the core package without requiring Apple Intelligence. The sample's simulator tests are run separately as described in its README.

Persistent storage, bounded reference/request composition, lifecycle helpers and the separate on-device example form the v0.1.0 candidate. Read the [changelog](CHANGELOG.md) and [compatibility guide](Guides/Compatibility.md) before integrating. The core package includes no model runtime, semantic search or automatic summarization.

## Contributing and releases

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development checks and [the release guide](Guides/Releasing.md) for the v0.1.0 publication sequence. [Release notes](RELEASE_NOTES.md) describe this first source release and its current limits.

## License

NovaContext is licensed under [Apache 2.0](LICENSE). See [NOTICE](NOTICE) for attribution. NovaGraph and its dependencies retain their own licenses and notices.
