# NovaContext

Persistent, scoped memory for Swift applications, backed by [NovaGraph](https://github.com/rhindsntc/NovaGraph).

NovaContext provides durable memory storage and deterministic context assembly with explicit byte limits and optional model-specific token limits. No model runtime or network service is required. A separate [on-device example](Examples/OnDeviceMemory/README.md) integrates Apple Foundation Models.

## Installation

Add this directory as a **local Swift package** in Xcode, or use a sibling package dependency:

```swift
.package(path: "../NovaContext")
```

Add the product to your target:

```swift
.product(name: "NovaContext", package: "novacontext")
```

The package uses Swift tools 6.0 and pins `GraphDBKit` from NovaGraph **1.0.0**. Declared deployment floors are iOS 16 and macOS 13. These declarations are separate from runtime qualification; the current storage tests were run on an Apple Silicon Mac with Swift 6.4 / macOS 27.0.1.

## Remember and recall

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
        let recalled = try await store.memory(id: saved.id, in: "project:nova")
        print(recalled?.text ?? "No memory")
        try await store.close()
    } catch {
        try? await store.close()
        throw error
    }
}
```

Keep the draft's UUID if you need to update or reconcile that record. Reopening the same directory returns previously committed memories. `remember` with the same UUID and scope replaces the entire payload, preserves `createdAtMs`, and updates `updatedAtMs`. Omitting a previous source or pin clears it. The same UUID can independently exist in another scope.

```swift
// Given an open store and the ID returned by remember:
try await store.forget(id: memoryID, in: "project:nova")
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

The defaults are **12 memories within 8 KiB**. Bytes include the header, metadata, and JSON escaping. To enforce an additional token allowance, pass `maxTokens` and your model's `TokenCounter`; NovaContext does not guess tokens from character counts. Keep separate room for instructions, the question, conversation, model formatting, and the response.

Read the [usage guide](Guides/Usage.md) for token integration, cancellation, empty-context behavior, and scope selection. Context assembly retrieves a coherent snapshot and releases the storage queue before tokenization.

## On-device example and lifecycle

The [SwiftUI example](Examples/OnDeviceMemory/README.md) lets you remember a decision, inspect the selected context, ask an on-device model, and explicitly forget or save an answer. It requires iOS 26+ for Foundation Models and includes a labelled model-free preview. Physical-device generation validation is pending.

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

Tests use real temporary Nova databases for persistence, replacement, deletion, scope isolation, concurrent capacity admission, UTF-8 validation, schema protection, and cancellation. Context tests cover deterministic ranking, complete rendered byte/token accounting, omissions, Unicode, scope isolation, and storage access during tokenization. Lifecycle tests cover suspension, failed transitions, cancellation forwarding, queue ordering and data preservation. A small internal mutation seam verifies error/receipt handling, including both possible outcomes of an ambiguous write; it is not a simulated power-loss qualification of Nova.

Persistent storage, bounded context assembly, lifecycle helpers, and the separate on-device example are implemented. Package CI, clean-consumer checks and final documentation are the next slice. The core package includes no model runtime, semantic search, or automatic summarization.
