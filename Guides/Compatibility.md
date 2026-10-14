# Compatibility and validation

NovaContext is a separate Swift package. The core stores explicit, scoped memory and returns a bounded reference block; applications choose the model and own its prompt and output.

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

- Core tests ran on an Apple Silicon Mac with Swift 6.4, Xcode 27.0 (27A266a) and macOS 27.0.1. The suite includes persistence, scope isolation, limits, context packing, cancellation and lifecycle errors. Debug and Release builds passed.
- OnDeviceMemory passed ten integration tests on 2026-10-14 on an iPhone 17 Pro simulator running iOS 26.5. These tests use real temporary databases and fake model/session boundaries; no actual LLM is required. The model-free launch/layout check and an unsigned iOS device build also passed.
- On 2026-10-14, the owner reported installing and testing OnDeviceMemory successfully. Device, OS, configuration, revision, mode and individual test outcomes were not supplied. This useful manual result does not imply completed device qualification or a measured performance budget.
- A complete recorded real-model device walkthrough, combined app/model memory observation and first-response latency observation remain open. Older declared deployment floors have not received a device test in this work.
- The GitHub Actions workflow checks the core on `macos-15` and prints its actual Xcode/Swift versions. A hosted run can only be confirmed after the repository is published and the workflow executes.

The local release handoff records candidate revisions, dependency resolution and exact commands. No package release/tag or production certification is implied by this document.

## Storage and integration limits

- One process/store exclusively owns a dedicated database directory. Do not share its handle or mix application graph data into the NovaContext schema. There is no multiprocess or cross-device synchronization layer.
- Schema version 1 is recognized. Other versions or malformed/unrelated stores fail explicitly; no schema migration or automatic reset is implemented.
- Each scope holds at most 128 memories. Text is limited to 4,096 UTF-8 bytes, scope to 128 bytes and source to 512 bytes. Applications manage total retained data; there is no silent eviction, TTL or automatic summarization.
- `context` defaults to 12 records and 8,192 bytes, with ceilings of 128 records and 65,536 bytes. Ranking is pinning/recency/UUID, not keyword or semantic relevance. Whole records that do not fit are omitted.
- Bytes include the reference header and JSON metadata/escaping. Tokens are optional and require a caller-supplied counter for the complete block. Final prompt/templates/output allowances belong to the application.
- Scoped reads and writes use Nova's existing resource and deadline limits. Bounded record counts are not a total-process memory or latency guarantee.
- Scopes partition retrieval; they do not implement authentication, application authorization, encrypted storage or secure erasure. Use appropriate app/platform storage protections for your data.
- Native storage errors propagate, including unknown commit outcomes. Preserve the ID/scope and reconcile recovered state before retrying; there is no automatic retry or exactly-once claim.
- Suspension failures keep ordinary access blocked until successful resume or close. An already-captured context value is a snapshot; deletion or suspension cannot revoke a value already returned to the app.

See [usage](Usage.md) for exact byte/token accounting, cancellation and lifecycle behavior, and the [example](../Examples/OnDeviceMemory/README.md) for running the UI and recording a device result.
