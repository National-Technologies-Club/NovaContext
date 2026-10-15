# On-device memory example

A small SwiftUI app that stores project decisions in NovaContext, exposes every stored memory for editing/pinning/deletion, and supplies scoped keyword matches to Apple's on-device Foundation Models framework. The app labels the exact reference context and answer with their submitted question. NovaContext itself has no model dependency.

## Run

Requirements: Xcode 26 or newer, XcodeGen, and iOS 26 or newer. Generation needs a device eligible for Apple Intelligence, with Apple Intelligence enabled and its on-device model ready. The UI reports model availability; remembering, inspecting, editing, pinning and deleting memories remain available without it. If the model becomes ready while the app stays open, use **Check model availability** to enable Ask without reopening the app. This check does not generate a response.

From the NovaContext repository root:

```sh
brew install xcodegen # if needed
xcodegen generate --spec Examples/OnDeviceMemory/project.yml
open Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj
```

Select the **OnDeviceMemory** scheme. For a physical device, select your signing team under Signing & Capabilities and choose your connected iPhone. Build and Run. Generated projects and signing selections are ignored by Git; make persistent build changes in `project.yml`.

For a simulator or a model-free walkthrough, add `--model-free` under **Edit Scheme → Run → Arguments Passed On Launch**. This mode returns a visibly labelled preview message and never invokes an LLM. It uses a separate local database so preview data does not enter the real demonstration store. Remove the argument when testing actual generation.

## Walk through it

1. Remember a short decision, such as “Use SQLite for cache.” Inspect **Stored memories** for the full list and **Recent / pinned preview** for the budget-selected context. Expand **Exact preview context**.
2. Remember a second record containing `cache` followed by about 3,000 ASCII characters. It fits the 4,096-byte memory-text limit but exceeds the 2,048-byte rendered-context allowance. Confirm that it still appears in **Stored memories** even though the preview omits it.
3. Choose **Edit** on that oversized record to open **Edit memory**. Use **Cancel** once to discard a draft, then change it to “Cache pages stay on device.” and **Save**. Try **Pin** and **Unpin**. The same record stays controllable, its origin/source are preserved, and the list and preview refresh.
4. Ask “cache SQLite”. The app captures that query, recalls matching text only in `project:demo`, and shows **Context for submitted question** with **Question: cache SQLite** and the **Exact reference context** used. The answer is labelled **Answer to: cache SQLite**. Stronger distinct-term matches come first; pinning breaks relevance ties. The model receives this block and the captured question, with fixed instructions in a separate session field.
5. Change the question field without pressing Ask. The previous context and answer keep their submitted-question labels. A successful remember, edit, pin/unpin, forget or clear invalidates the old answer and refreshes the current preview; after a query, that preview still belongs to the last submitted question.
6. Ask for a term absent from all saved text, such as `quasarzephyr`. The reference context is empty: the app does not fall back to recent or pinned memories. Punctuation/emoji-only input, such as `🪐`, is rejected because it contains no searchable term. Real generation can still use the model's own knowledge when there are no stored matches.
7. Generated answers are not saved automatically. In real-model mode, **Save answer as model memory** explicitly persists a response with origin `model` and a source description; this action is hidden in model-free preview. Edit or pin that record and confirm its provenance stays visible. Forget a record, then repeat a query that matched it; the next context must exclude the deleted record.
8. Close/open the store, then terminate/relaunch the app to check persistence. Background/return and **Trim cached memory** should preserve saved content. **Clear project memories** removes the complete scope after confirmation, including records omitted from the preview.

The sample uses one scope, `project:demo`, and an Application Support database. It does not provide browsing of other scopes, graph editing, extraction, or model tools. Reference text is data; it is never substituted into system instructions or executed as NGQL.

## Bounds and lifecycle

- The stored list contains every memory in `project:demo`, up to the SDK's **128-record** scope limit, independently of context selection.
- At most **4 records** and **2,048 UTF-8 bytes** of rendered reference context. The first preview uses pinned/recent ordering; submitted questions use keyword recall with no automatic fallback.
- A question of at most **1,024 UTF-8 bytes before normalization**, containing at least one searchable Unicode letter/number term. Whole terms are case-folded and canonically normalized; repeated query terms add no weight. Punctuation/emoji-only input is invalid. See the [SDK recall contract](../../Guides/Usage.md#recall-matching-memories).
- A maximum response allowance of **256 tokens** supplied to Foundation Models.
- These small input byte bounds are **not a token-window guarantee**. No approximate tokenizer is supplied. A context-window error produces one visible failure; shorten the input before trying again. There are no automatic generation retries.
- A fresh `LanguageModelSession` is created for each question. Requests do not accumulate an invisible transcript, and concurrent generation is disabled.
- Backgrounding cancels generation and queues suspension; foregrounding queues resume and refresh. Fast scene changes preserve this order. The OS can still terminate the app before background work finishes; acknowledged writes are already durable.
- Trimming removes cached records, not persistent memories. Close is explicit and errors remain visible. The core package contains no SwiftUI or UIKit dependency.

## Tests

From the repository root, select an available simulator UDID from `xcrun simctl list devices available`. The recorded run used the destination below; replace its UDID if needed:

```sh
swift test --filter LifecycleTests
xcodegen generate --spec Examples/OnDeviceMemory/project.yml
xcodebuild test \
  -project Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj \
  -scheme OnDeviceMemory \
  -destination 'platform=iOS Simulator,id=DEFD4F9D-2CB1-431F-A464-C9A970CA73C4' \
  -derivedDataPath build/OnDeviceMemory \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

The sample integration tests use real temporary Nova databases and fake responders. They verify access to records omitted from context, targeted text/pin edits, provenance and persistence, stale-edit deletion without resurrection, captured-question prompt/context/answer identity, no-match behavior, scope isolation, query and byte bounds, model-unavailable controls, cancellation, lifecycle sequencing, fresh sessions, and no hidden retry on context-window failure. The test host opens no demonstration database.

Local validation on 2026-10-12 used Xcode 27.0 (27A266a) and the iPhone 17 Pro simulator on iOS 26.5. Nine sample tests passed, and an unsigned iOS device build succeeded. These tests and the model-free launch/layout check do not validate actual on-device generation. Older declared core deployment targets are not device-qualified by this run.

**Owner-reported sample result (2026-10-14):** the owner installed and tested OnDeviceMemory and reported that it worked well. Device, OS, build configuration, source revision, individual walkthrough outcomes and real-model versus preview mode were not specified, so this is recorded as a successful manual sample report, not a completed qualification matrix.

On 2026-10-14, all 13 sample integration tests in one suite passed with Xcode 27.0 (27A266a) on the iPhone 17 Pro simulator running iOS 26.5, UDID `DEFD4F9D-2CB1-431F-A464-C9A970CA73C4`, using the `xcodebuild test` command above. Swift Testing reported 0.985 seconds; `xcodebuild` reported `TEST SUCCEEDED`. This run covers the controls and query-specific recall behavior. A separate automated model-free UI walkthrough passed on the same simulator: one UI test, zero failures, 63.608 seconds. It covered Remember, persistence after relaunch, Edit Cancel/Save, Pin/Unpin, matching and unmatched queries, captured labels after input changes, and Forget. That walkthrough did not invoke an LLM.

The remaining detailed record is the walkthrough above on an eligible iPhone with real generation, plus one observation of combined app/model memory and first-response latency in Xcode. Record the device, OS, build configuration, NovaContext revision and resolved NovaGraph revision. See [compatibility and validation](../../Guides/Compatibility.md).

API references: [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession).
