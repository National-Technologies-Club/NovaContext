# On-device memory example

A small SwiftUI app that stores project decisions in NovaContext, exposes every stored memory for editing/pinning/deletion, and supplies scoped keyword matches to Apple's on-device Foundation Models framework. The bounded composer combines the selected references, fixed instructions and captured question into one inspectable request. During generation, one read-only tool lets the model search the same project notes with another keyword query. The app labels the initial context, composed input, later search results and answer with their submitted question. NovaContext itself has no model dependency.

## Run

Requirements: Xcode 26 or newer, XcodeGen, and iOS 26 or newer. Generation needs a device eligible for Apple Intelligence, with Apple Intelligence enabled and its on-device model ready. The UI reports model availability; remembering, inspecting, editing, pinning and deleting memories remain available without it. If the model becomes ready while the app stays open, use **Check model availability** to enable Ask without reopening the app. This check does not generate a response.

From the NovaContext repository root:

```sh
brew install xcodegen # if needed
xcodegen generate --spec Examples/OnDeviceMemory/project.yml
open Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj
```

Select the **OnDeviceMemory** scheme. For a physical device, select your signing team under Signing & Capabilities and choose your connected iPhone. Build and Run. Generated projects and signing selections are ignored by Git; make persistent build changes in `project.yml`.

For a simulator or a model-free walkthrough, add `--model-free` under **Edit Scheme → Run → Arguments Passed On Launch**. This mode returns a visibly labelled preview message and never invokes a model or tools. It uses a separate local database so preview data does not enter the real demonstration store. Remove the argument when testing actual generation.

## Walk through it

1. Remember a short decision, such as “Use SQLite for cache.” Inspect **Stored memories** for the full list and **Recent / pinned preview** for the budget-selected context. Expand **Exact preview context**.
2. Remember a second record containing `cache` followed by about 3,000 ASCII characters. It fits the 4,096-byte memory-text limit but exceeds the 2,048-byte rendered-context allowance. Confirm that it still appears in **Stored memories** even though the preview omits it.
3. Choose **Edit** on that oversized record to open **Edit memory**. Use **Cancel** once to discard a draft, then change it to “Cache pages stay on device.” and **Save**. Try **Pin** and **Unpin**. The same record stays controllable, its origin/source are preserved, and the list and preview refresh.
4. Ask “cache SQLite”. The app captures that query, recalls matching text only in `project:demo`, and shows **Context for submitted question** with **Question: cache SQLite** and the **Exact reference context** used. Expand **Composed input** to inspect separate **Instructions** and **Prompt** fields, plus the combined UTF-8 byte count out of **4,096**. These exact initial strings go to the model adapter, before native tool definitions and later exchanges; the selected-memory preview comes from the composer's final `memoryContext`. The answer is labelled **Answer to: cache SQLite**. Stronger distinct-term matches come first; pinning breaks relevance ties. Instructions stay separate from the reference data and question.
5. Change the question field without pressing Ask. The previous context, composed request and answer keep their submitted-question identity. A successful remember, edit, pin/unpin, forget or clear invalidates the old answer and tool results and refreshes/recomposes the current preview without calling the model; after a query, that preview still belongs to the last submitted question. A failed refresh clears the old request and selected-context preview rather than presenting them as current.
6. Ask for a term absent from all saved text, such as `quasarzephyr`. The reference context is empty: the app does not fall back to recent or pinned memories. Punctuation/emoji-only input, such as `🪐`, is rejected because it contains no searchable term. During real generation the model may search with alternate keywords; the initial recall display stays unchanged. If neither initial recall nor a later search finds saved facts, the instructions ask the model to say so.
7. Generated answers are not saved automatically. In real-model mode, **Save answer as model memory** explicitly persists a response with origin `model` and a source description; this action is hidden in model-free preview. Edit or pin that record and confirm its provenance stays visible. Forget a record and inspect the refreshed request for the last submitted question: it must exclude the deleted record. Asking again uses that newly composed input.
8. Close/open the store, then terminate/relaunch the app to check persistence. Background/return and **Trim cached memory** should preserve saved content. **Clear project memories** removes the complete scope after confirmation, including records omitted from the preview.

The sample uses one scope, `project:demo`, and an Application Support database. It does not provide browsing of other scopes, graph editing or automatic extraction. The tool is internal to this sample; NovaContext has no public tool registry or plugin API. Reference text is data; it is never substituted into system instructions or executed as NGQL.

## On-demand project-note search

Each fresh native session registers one `search_project_notes(query:)` tool. The model chooses whether to call it and which keywords to use; no call is required for every question. The host binds the reader to the current store and `project:demo`, so the tool cannot choose a scope, database path or NGQL statement. It uses the SDK's existing whole-term keyword recall, without semantic search or stemming.

| Per submitted question | Allowance |
| --- | ---: |
| Admitted search attempts, including invalid queries | 2 |
| Original query | 1,024 UTF-8 bytes; nonblank with a searchable term |
| Records per search | 4 |
| Complete returned text per search | 2,048 UTF-8 bytes |

The tool returns the complete rendered recall text, including IDs and provenance, unchanged. No matches return exactly `No matching project notes.`. Oversized results fail without truncation, and a third call is rejected before reading. Search errors are surfaced without an application-level generation retry.

After generation succeeds or fails, **Project-note searches** shows the captured question and each admitted query, selected memory IDs and the exact text under **Returned project notes**, or a short failure/discarded status. These later results are separate from **Composed input** and do not alter its initial 4,096-byte count. Tool records remain in memory only; **Save answer as model memory** is still the explicit answer-persistence action. A new Ask, successful memory change or failed refresh clears the old tool display. Model-free mode explicitly reports that no model or tools were called.

For a short real-model check, save `Cache choice: Riverstone.` and ask `What did we choose for caching?`. The initial whole-term recall has no matches. If the model calls the tool with `cache`, inspect the returned Riverstone record and its ID, then confirm the stored-memory count is unchanged. Model choice is nondeterministic: no call or a different query is an observation to record, not proof of a broken reader. This real-model walkthrough remains pending; scripted tests establish the retrieval and display plumbing only.

## Bounds and lifecycle

- The stored list contains every memory in `project:demo`, up to the SDK's **128-record** scope limit, independently of context selection.
- At most **4 records** and **2,048 UTF-8 bytes** of rendered reference context. The first preview uses pinned/recent ordering; submitted questions use keyword recall with no automatic fallback.
- A question of at most **1,024 UTF-8 bytes before normalization**, containing at least one searchable Unicode letter/number term. Whole terms are case-folded and canonically normalized; repeated query terms add no weight. Punctuation/emoji-only input is invalid. See the [SDK recall contract](../../Guides/Usage.md#recall-matching-memories).
- At most **4,096 combined UTF-8 bytes** for `ComposedInput.instructions` plus `ComposedInput.prompt`, including fixed text, rendered memory metadata and JSON escaping. The composer preserves recall order and keeps whole records only. A mandatory-input fit failure is visible; generation does not proceed with a partial request. See the [SDK composer contract](../../Guides/Usage.md#compose-a-bounded-model-request).
- A maximum response allowance of **256 tokens** supplied to Foundation Models.
- The initial composition and per-search text bounds exclude native tool definitions, argument encoding, transcript framing and later exchanges. They are **not a token-window guarantee**. No approximate tokenizer is supplied. A context-window error produces one visible failure; shorten the input before trying again. There are no automatic generation retries.
- A fresh `LanguageModelSession` is created for each question. The sample passes explicit history `[]` and does not capture/save a conversation automatically. Questions do not share a transcript; native tool exchanges can occur within one question. Concurrent native generation is disabled. Cancellation is cooperative: a new native Ask may report busy until an uncooperative earlier model response exits.
- Backgrounding and close cancel generation and await search invalidation before queuing storage transitions, without waiting indefinitely for the model. Late results cannot publish into a newer or inactive request. Backgrounding queues suspension; foregrounding queues resume and refresh. Fast scene changes preserve this order. The OS can still terminate the app before background work finishes; acknowledged writes are already durable.
- Trimming removes cached records, not persistent memories. Close is explicit and errors remain visible. The core package contains no SwiftUI or UIKit dependency.

## Tests

From the repository root, select an available simulator UDID from `xcrun simctl list devices available`. The recorded run used the destination below; replace its UDID if needed:

```sh
swift test
xcodegen generate --spec Examples/OnDeviceMemory/project.yml
xcodebuild test \
  -project Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj \
  -scheme OnDeviceMemory \
  -destination 'platform=iOS Simulator,id=DEFD4F9D-2CB1-431F-A464-C9A970CA73C4' \
  -derivedDataPath build/OnDeviceMemory \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

The sample integration tests use real temporary Nova databases and fake responders. They verify access to records omitted from context, targeted text/pin edits, provenance and persistence, stale-edit deletion without resurrection, captured-question context/request/answer identity, exact separate instruction/prompt forwarding, combined byte accounting, recomposition after edit/delete without generation, failed-refresh cleanup, no-match behavior, scope isolation, query bounds, model-unavailable controls, cancellation, lifecycle sequencing, fresh sessions, and no hidden retry on context-window failure. The test host opens no demonstration database.

Local validation on 2026-10-12 used Xcode 27.0 (27A266a) and the iPhone 17 Pro simulator on iOS 26.5. Nine sample tests passed, and an unsigned iOS device build succeeded. These tests and the model-free launch/layout check do not validate actual on-device generation. Older declared core deployment targets are not device-qualified by this run.

**Owner-reported sample result (2026-10-14):** the owner installed and tested OnDeviceMemory and reported that it worked well. Device, OS, build configuration, source revision, individual walkthrough outcomes and real-model versus preview mode were not specified, so this is recorded as a successful manual sample report, not a completed qualification matrix.

On 2026-10-14, all 13 sample integration tests in one suite passed with Xcode 27.0 (27A266a) on the iPhone 17 Pro simulator running iOS 26.5, UDID `DEFD4F9D-2CB1-431F-A464-C9A970CA73C4`, using the `xcodebuild test` command above. Swift Testing reported 0.985 seconds; `xcodebuild` reported `TEST SUCCEEDED`. This run covers the controls and query-specific recall behavior. A separate automated model-free UI walkthrough passed on the same simulator: one UI test, zero failures, 63.608 seconds. It covered Remember, persistence after relaunch, Edit Cancel/Save, Pin/Unpin, matching and unmatched queries, captured labels after input changes, and Forget. That walkthrough did not invoke an LLM.

On 2026-10-17, all **15 sample integration tests** in one suite passed with Xcode 27.0 (27A266a), Debug, on that iPhone 17 Pro / iOS 26.5 simulator. Swift Testing reported 1.127 seconds and `xcodebuild` reported `TEST SUCCEEDED`. This run adds the bounded composition integration, exact request preview/forwarding, edit/delete recomposition and failed-refresh cleanup. The core package suite also passed all **82 tests across six suites**. These tests use fake responders and do not qualify actual model generation on a physical device.

A separate, temporary model-free UI test passed on 2026-10-17 using a disposable iPhone 17 Pro / iOS 26.5 simulator: **one test, zero failures, 48.027 seconds**. It covered Remember, Ask, separate exact instructions/prompt and combined byte count, submitted-question identity after changing the input field, Edit/Save recomposition and Forget. The walkthrough did not call an LLM and adds no permanent UI-test target to the sample.

The sample-only search implementation at `9201f4d` passed **28 tests across two suites** on 2026-10-17, Debug, on iPhone 17 Pro / iOS 26.5 simulator `DEFD4F9D-2CB1-431F-A464-C9A970CA73C4`: 3.756 seconds, `TEST SUCCEEDED`. This includes native-tool invocation with a scripted responder, exact Riverstone retrieval after empty initial recall, fixed scope, no writes, query/output/admission limits, concurrent calls and cancellation/background/close with late completions. These deterministic checks do not establish real model tool selection or answer quality.

The same source passed a Release sample build with Xcode 27.0 (27A266a), Swift 6.4 and resolved NovaGraph 1.0.0 (`5af2471965d33843b81a2aac3140e8c0b3c92233`):

```sh
xcodebuild build \
  -project Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj \
  -scheme OnDeviceMemory -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/OnDeviceMemory CODE_SIGNING_ALLOWED=NO
```

The unchanged core passed 82 tests across six suites again in 10.858 seconds. This unsigned simulator build does not qualify real-device generation.

On 2026-10-17, the search-tool sample at `9201f4d` also passed a focused, temporary model-free UI walkthrough: **one test, zero failures, 30.493 seconds**, Debug, on a disposable iPhone 17 Pro / iOS 26.5 simulator. It checked Remember, enabled Edit/Pin/Forget, separate composed instructions/prompt and the 4,096-byte count, the captured question, truthful no-model/no-tools answer and search state, no tool-call record, and the storage controls. It did not invoke a model or qualify actual tool selection. No permanent UI-test target was added.

The remaining detailed record is the walkthrough above on an eligible iPhone with real generation, plus one observation of combined app/model memory and first-response latency in Xcode. Record the device, OS, build configuration, NovaContext revision and resolved NovaGraph revision. See [compatibility and validation](../../Guides/Compatibility.md).

API references: [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession).
