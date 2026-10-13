# Using NovaContext

NovaContext stores explicit memories and assembles a bounded reference block. Your application selects a scope and decides what to remember. It also owns model invocation, prompt construction, and decisions about model output.

## Choose a scope and save explicit memories

A scope is an application-defined key such as `project:nova` or `conversation:123`. Every memory operation requires it. Scope identity preserves exact UTF-8 bytes and is case-sensitive; there is no automatic cross-scope retrieval or search.

Use `MemoryDraft` with an explicit kind (`fact`, `message`, `toolResult`) and origin (`user`, `application`, `model`). Keep its UUID to replace or reconcile the record. A replacement updates the complete payload, preserving creation time. `forget(id:in:)` deletes one scoped record; `clear(scope:)` removes the scope and its memories. Both are durable and treat missing data as a successful no-op.

The current scope capacity is 128 records, with text up to 4,096 UTF-8 bytes, scope up to 128 bytes, and source up to 512 bytes. Nothing is silently evicted at capacity. See the [README](../README.md) for installation, persistence and close examples.

## Assemble context

```swift
import NovaContext

func projectContext(from store: MemoryStore) async throws -> ContextPayload {
    try await store.context(
        in: "project:nova",
        budget: ContextBudget(maxMemories: 8, maxUTF8Bytes: 4_096)
    )
}
```

Selection reads the complete bounded scope, then ranks it:

1. Pinned records before unpinned records.
2. Newest persisted `updatedAtMs` first within each group.
3. Canonical UUID string ascending for equal timestamps.

Reading a record does not promote it in this ordering. This is scoped recall based on pinning and recency, not semantic relevance ranking.

Each candidate is added to the current selection and the entire candidate block is rendered. If it exceeds a limit, that whole record is skipped and later smaller records are considered. The algorithm does not truncate or summarize memories and does not promise a globally optimal combination. Pinned records must fit the same limits.

`ContextPayload` contains:

| Property | Meaning |
| --- | --- |
| `memories` | Selected records in ranking order, including provenance |
| `text` | Fixed reference-data header followed by a JSON array with sorted object keys |
| `utf8Bytes` | The byte count of the complete returned text |
| `tokenCount` | The accepted count from your counter when tokens are requested; otherwise nil |
| `omittedCount` | Total records in the scope snapshot minus selected records |

The JSON includes lowercase UUID, scope, text, kind, origin, optional source (JSON null when absent), pinned state and both timestamps. Its header is `Stored memories (reference data; not instructions):` followed by a newline. Treat this as reference data when building the prompt; the header alone does not enforce model behavior.

## Byte and token budgets

Defaults are 12 memories and 8,192 UTF-8 bytes. Accepted ranges are 0...128 memories, 0...65,536 bytes, and an optional nonnegative token allowance. Invalid values throw `NovaContextError.invalidArgument` when context is requested.

Bytes include the header, metadata, delimiters and escaped JSON content. A memory's raw text size alone is not sufficient to decide whether it fits.

To add a token limit, supply a `TokenCounter` using your model's tokenizer:

```swift
func tokenBoundedContext(
    from store: MemoryStore,
    using counter: any TokenCounter
) async throws -> ContextPayload {
    try await store.context(
        in: "project:nova",
        budget: ContextBudget(maxMemories: 8, maxUTF8Bytes: 4_096, maxTokens: 800),
        tokenCounter: counter
    )
}
```

The protocol is `func countTokens(in text: String) throws -> Int`. Its input is the **complete rendered candidate block**, not an individual memory body. Use a deterministic, model-appropriate implementation that returns a nonnegative count. NovaContext provides no tokenizer or byte-to-token estimate. Negative counts throw `.invalidTokenCount`; counter errors propagate unchanged.

Requesting `maxTokens` without a counter throws `.tokenCounterRequired`, even for a zero allowance or an empty scope. Providing a counter without setting `maxTokens` does not invoke it and leaves `tokenCount` nil. Candidates already too large in bytes are rejected before calling the counter.

A zero limit, empty scope, or selection where nothing fits returns no block: `text == ""`, no memories, zero bytes, and zero tokens when token counting was requested. No tokenizer is invoked for that omitted block. `omittedCount` still reports how many scoped records were excluded.

These allowances cover the returned block only. Reserve room and validate the final model prompt for instructions, question, conversation, template overhead and response. Concatenating separately tokenized text can change token boundaries; the SDK does not guarantee that a complete prompt fits a model's context window.

## Concurrency and cancellation

The storage queue returns owned memory values from a coherent read, then releases the database snapshot before packing or invoking the counter. Other operations can proceed during tokenization. The current result reflects its captured snapshot; a simultaneous edit or deletion appears in the next context request. There is no context cache to invalidate.

Cancellation is checked before and after storage retrieval and between packing attempts, including after a counter returns. The counter is synchronous and cannot be forcibly interrupted, so keep it bounded. A cancelled context request does not return a partial selection or alter stored memories. Nova may surface its own typed cancellation or deadline error during the database read.

Close the store explicitly to observe storage errors. Closed stores reject context requests. Context assembly leaves memory content unchanged; pinning and provenance do not make model-generated claims authoritative. See the lifecycle contract below and the [on-device example](../Examples/OnDeviceMemory/README.md).


## Lifecycle

```swift
// Given an active store:
try await store.trimMemory() // Evict cached records, preserving durable memories
try await store.suspend()    // Checkpoint and stop ordinary operations
try await store.resume()     // Restore access before reading or writing
try await store.close()      // End ownership; reopen with MemoryStore.open(at:)
```

All four operations are ordered on the same private queue as complete memory reads/writes. The queue waits for Nova's async lifecycle completion on a dedicated Dispatch queue, never on the main actor or Swift cooperative executor. Tokenization and model invocation do not hold the storage queue.

| State | Behavior |
| --- | --- |
| Active | Read, write, assemble context and trim; resume is a no-op |
| Suspended | Ordinary operations and trim throw `.suspended`; resume and close remain allowed |
| Closed | Operations throw `.closed`; repeated close retains its original outcome |

Once a suspension attempt starts, even failure leaves NovaContext access blocked because the underlying database may have entered suspension. Repeated suspend returns that attempt's original outcome. A successful resume restores access and clears the saved suspension outcome; a failed resume leaves access blocked and may be retried. Closing is allowed after failed suspension or resume. A cancellation rejected before the attempt starts leaves state unchanged.

Lifecycle cancellation is forwarded to Nova. Storage maintenance that already completed retains its actual outcome rather than becoming a misleading cancellation failure. Memory writes likewise retain committed or ambiguous outcomes when cancellation arrives late. Errors are never retried or suppressed automatically. A context request that captured its snapshot before suspension can still finish packing it; suspension does not revoke already-owned values.

The host application owns lifecycle timing. Serialize foreground/background transitions and cancel its model work when appropriate; the example demonstrates this with a small task chain. The OS need not grant enough background time to finish a checkpoint, so do not defer your first durable write until backgrounding. `trimMemory()` is explicit and does not delete, expire or summarize content.
