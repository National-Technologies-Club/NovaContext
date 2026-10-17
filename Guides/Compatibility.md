# Compatibility and validation

NovaContext is a separate Swift package. The core stores explicit, scoped memory, returns bounded reference blocks and can compose a bounded initial request; applications choose the model adapter and own its output.

## Declared support

| Component | Requirements |
| --- | --- |
| Core package | Swift tools 6.0; iOS 16+ or macOS 13+ |
| Storage dependency | Published NovaGraph 1.0.0, product `GraphDBKit` |
| OnDeviceMemory example | Xcode 26+, XcodeGen, iOS 26+ |
| Real example generation | An eligible device with Apple Intelligence enabled and its on-device model ready |

The core imports Foundation, Dispatch and GraphDBKit. Foundation Models, SwiftUI and model availability checks live in the separate example. No model downloads, network inference, embedding service or model runtime is managed by the core package.

These deployment floors are declarations, not a claim that every OS/device combination has been exercised. NovaGraph's own support and limitations also apply.

## Validation status

- The core suite passed all **82 tests across six suites** on 2026-10-17, using an Apple Silicon Mac with Swift 6.4 and Xcode 27.0 (27A266a). It includes persistence, full scoped listing, targeted edits, scope isolation, limits, keyword recall, memory packing, whole-request composition, asynchronous counting/cancellation and lifecycle errors. Debug and Release builds passed. A fresh archived-source downstream executable resolved NovaGraph 1.0.0 at `5af2471965d33843b81a2aac3140e8c0b3c92233`, compiled with only public imports and ran store → recall → compose → close, including explicit history and an asynchronous request-counter fixture. It used an independent consumer build directory, without the SDK checkout's `.build`. The local handoff records exact SDK revisions and logs.
- OnDeviceMemory passed all **15 integration tests** in one suite on 2026-10-17 with Xcode 27.0 (27A266a), Debug, using an iPhone 17 Pro simulator on iOS 26.5. Swift Testing reported 1.180 seconds and `xcodebuild` reported `TEST SUCCEEDED`. These tests use real temporary databases and fake model/session boundaries; no actual LLM is required. The [sample test instructions](../Examples/OnDeviceMemory/README.md#tests) record the destination and command. A separate temporary model-free UI test passed on a disposable iPhone 17 Pro / iOS 26.5 simulator: one test, zero failures, 48.027 seconds. It checked exact separate instructions/prompt, combined bytes, submitted-question identity and edit/delete recomposition without calling a real model. Earlier controls, persistence and no-match walkthrough results remain recorded in the sample README.
- On 2026-10-14, the owner reported installing and testing OnDeviceMemory successfully. Device, OS, configuration, revision, mode and individual test outcomes were not supplied. This useful manual result does not imply completed device qualification or a measured performance budget.
- A complete recorded real-model device walkthrough, combined app/model memory observation and first-response latency observation remain open. Older declared deployment floors have not received a device test in this work.
- The GitHub Actions workflow checks the core on `macos-15` and prints its actual Xcode/Swift versions. A hosted run can only be confirmed after the repository is published and the workflow executes.

The local release handoff records candidate revisions, dependency resolution and exact commands. No package release/tag or production certification is implied by this document.

## Storage and integration limits

- One process/store exclusively owns a dedicated database directory. Do not share its handle or mix application graph data into the NovaContext schema. There is no multiprocess or cross-device synchronization layer.
- Schema version 1 is recognized. Other versions or malformed/unrelated stores fail explicitly; no schema migration or automatic reset is implemented.
- Each scope holds at most 128 memories. Text is limited to 4,096 UTF-8 bytes, scope to 128 bytes and source to 512 bytes. Applications manage total retained data; there is no silent eviction, TTL or automatic summarization.
- `memories(in:)` returns one coherent full list of up to 128 scoped records, including those omitted from context. It applies no context or token budget, uses pin/update-time/UUID order, and throws on read/validation failures rather than returning a partial list. A missing scope returns `[]`.
- `update(id:in:text:pinned:)` atomically changes only supplied text/pinning and preserves other fields, including creation time and model provenance. Nil leaves a field unchanged; unchanged text bytes and pinning cause no write or timestamp change. Missing records return nil without being recreated, while invalid supplied text still throws. Disjoint field changes are preserved; the last same-field change applied on the queue wins. `remember` keeps its complete-replacement/upsert contract.
- `context` selects by pinning/recency/UUID. `recall` searches only text in one exact scope using canonically normalized, case-folded whole Unicode terms. It ranks by distinct query terms matched, then pinning/recency/UUID; repetition adds no weight. It provides no semantic, stemming, fuzzy/prefix, phrase/regex or language-specific word search.
- Recall queries are limited to 1,024 original UTF-8 bytes and require at least one searchable letter/number term. Invalid queries throw `.invalidArgument`. Normalization does not rewrite stored values; matching preserves accents and ignores source metadata.
- `context` and `recall` default to 12 records and 8,192 bytes, with ceilings of 128 records and 65,536 bytes. Whole records that do not fit are omitted without reordering, truncation or a pin exception. Recall returns an empty payload for no matches; a recent/pinned fallback requires an explicit `context` call. Both report every unselected scoped record in `omittedCount`, including recall nonmatches.
- Memory-block bytes include the reference header and JSON metadata/escaping. Optional memory tokens use the existing synchronous `TokenCounter`. `ContextComposer` can instead bound complete instructions + prompt strings with an optional asynchronous `RequestTokenCounter`; those are separate counting contracts.
- `CompositionBudget` defaults to 16,384 combined UTF-8 bytes and four history turns; ceilings are 65,536 bytes and 32 turns. Instructions are capped at 8,192 bytes, a nonblank question at 1,024 original bytes, and each nonblank user/assistant history field at 4,096 bytes. Mandatory content must fit or `.requiredInputTooLarge` is thrown. Whole memories preserve supplied order; history is a chronological contiguous suffix, with memories receiving priority. No prior omitted candidates are recovered or data truncated/summarized.
- A whole-input token cap requires an async request counter. Reservation is nonnegative, requires a cap when nonzero and cannot exceed it. All byte-fitting candidates are counted as complete input; counters without a cap are not called. Counts cover the returned fields under the supplied counter. The adapter must account for additional framing, native history, tools, schemas and output; reservation does not automatically bound later tool traffic. No provider tokenizer or model-window estimate is supplied.
- OnDeviceMemory keeps its full stored-memory list separate from context, supports targeted text/pin controls with provenance visible, and captures each submitted question for scoped recall. Its rendered references are bounded to four records and 2,048 bytes; questions are bounded to 1,024 original UTF-8 bytes and need a searchable term. It composes at most 4,096 combined instruction/prompt bytes with history `[]`, forwards those exact separate fields and shows the request/count for inspection. No-match recall has no automatic fallback. Memory changes invalidate old answers and recompose the last submitted query without generation; failed refresh clears old context and request data.
- Scoped reads and writes use Nova's existing resource and deadline limits. Bounded record counts are not a total-process memory or latency guarantee.
- Scopes partition retrieval; they do not implement authentication, application authorization, encrypted storage or secure erasure. Use appropriate app/platform storage protections for your data.
- Native storage errors propagate, including unknown commit outcomes. Preserve the ID/scope and reconcile recovered state before retrying; there is no automatic retry or exactly-once claim.
- Suspension failures keep ordinary access blocked until successful resume or close. An already-captured context value is a snapshot; deletion or suspension cannot revoke a value already returned to the app.

See [usage](Usage.md) for exact byte/token accounting, cancellation and lifecycle behavior, and the [example](../Examples/OnDeviceMemory/README.md) for running the UI and recording a device result.
