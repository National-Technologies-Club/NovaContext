# NovaContext v0.1.0

Prepared release notes for [National-Technologies-Club/NovaContext](https://github.com/National-Technologies-Club/NovaContext). The public repository has been created; source publication, the version tag and the GitHub release remain pending.

NovaContext brings persistent, scoped memory and bounded context assembly to Swift applications. It uses NovaGraph 1.0.0 for storage and lets your application choose its model and what to remember.

## Included

- Explicit memories with UUIDs, kind, origin, source, pinning and timestamps.
- Full scoped listing, targeted text/pin edits, durable forget/clear and explicit lifecycle operations.
- Whole-term keyword recall with deterministic ranking and complete-record byte/token packing.
- A context composer for separate instructions and prompt, selected memories, explicit recent history and a question, with optional caller-supplied token counting.
- An iOS 26+ Foundation Models sample with memory controls, inspectable composed input and one bounded read-only project-note search tool.

## Requirements and limits

The core uses Swift tools 6.0 with declared iOS 16/macOS 13 floors. These floors are not a complete tested-device matrix. The sample requires Xcode 26+, iOS 26+ and an eligible, enabled Apple Intelligence model for actual generation; model-free preview is available separately.

Each scope holds up to 128 memories. Memory text fits 4,096 UTF-8 bytes. Context and composition limits count rendered data; token limits require the application's counters. Native framing and later tool exchanges require separate model-context accounting. Scopes do not provide authentication or encryption, and one store/process owns a database directory.

Physical-device testing, real-model search-tool selection and app/model memory/latency qualification remain pending. Local core, simulator and clean-consumer checks are recorded in [compatibility](Guides/Compatibility.md). Hosted CI and installation from the eventual GitHub tag must be checked after publication.

The search tool lives in the sample. The core supplies no generic plugin API, model runtime, semantic retrieval, automatic extraction or summarization.
