# On-device memory example

A small SwiftUI app that stores project decisions in NovaContext and supplies selected memories to Apple's on-device Foundation Models framework. The app shows the exact reference context beside the answer. NovaContext itself has no model dependency.

## Run

Requirements: Xcode 26 or newer, XcodeGen, and iOS 26 or newer. Generation needs a device eligible for Apple Intelligence, with Apple Intelligence enabled and its on-device model ready. The UI reports model availability; remembering, inspecting and deleting memories remain available without it.

From the NovaContext repository root:

```sh
brew install xcodegen # if needed
xcodegen generate --spec Examples/OnDeviceMemory/project.yml
open Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj
```

Select the **OnDeviceMemory** scheme. For a physical device, select your signing team under Signing & Capabilities and choose your connected iPhone. Build and Run. Generated projects and signing selections are ignored by Git; make persistent build changes in `project.yml`.

For a simulator or a model-free walkthrough, add `--model-free` under **Edit Scheme → Run → Arguments Passed On Launch**. This mode returns a visibly labelled preview message and never invokes an LLM. It uses a separate local database so preview data does not enter the real demonstration store. Remove the argument when testing actual generation.

## Walk through it

1. Remember a short decision, such as “Use SQLite for the cache.”
2. Inspect **Selected memories** and expand the exact-context preview.
3. Ask “What should the cache use?” The model receives only the selected reference block and this question, with fixed instructions in a separate session field.
4. Close/open the store, then terminate/relaunch the app. The decision should remain.
5. Forget the decision and ask again. The next context must exclude it. Generated answers are not saved automatically. **Save answer as model memory** explicitly persists a response with origin `model`.
6. Background/return and use **Trim cached memory**. Both should preserve saved content. **Clear project memories** also removes records omitted from the preview after confirmation.

The sample uses one scope, `project:demo`, and an Application Support database. It does not provide browsing of other scopes, graph editing, extraction, or model tools. Reference text is data; it is never substituted into system instructions or executed as NGQL.

## Bounds and lifecycle

- At most **4 records** and **2,048 UTF-8 bytes** of rendered reference context.
- A nonblank question of at most **1,024 UTF-8 bytes**.
- A maximum response allowance of **256 tokens** supplied to Foundation Models.
- These small input byte bounds are **not a token-window guarantee**. No approximate tokenizer is supplied. A context-window error produces one visible failure; shorten the input before trying again. There are no automatic generation retries.
- A fresh `LanguageModelSession` is created for each question. Requests do not accumulate an invisible transcript, and concurrent generation is disabled.
- Backgrounding cancels generation and queues suspension; foregrounding queues resume and refresh. Fast scene changes preserve this order. The OS can still terminate the app before background work finishes; acknowledged writes are already durable.
- Trimming removes cached records, not persistent memories. Close is explicit and errors remain visible. The core package contains no SwiftUI or UIKit dependency.

## Tests

From the repository root, select an available simulator UDID from `xcrun simctl list devices available`:

```sh
swift test --filter LifecycleTests
xcodegen generate --spec Examples/OnDeviceMemory/project.yml
xcodebuild test \
  -project Examples/OnDeviceMemory/OnDeviceMemory.xcodeproj \
  -scheme OnDeviceMemory \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath build/OnDeviceMemory \
  CODE_SIGNING_ALLOWED=NO
```

The hosted tests use real temporary Nova databases and fake responders. They verify prompt contents, scope/deletion isolation, byte bounds, model-unavailable state, explicit model provenance, cancellation, lifecycle sequencing, fresh sessions, and no hidden retry on context-window failure. The test host opens no demonstration database.

Local validation on 2026-10-12 used Xcode 27.0 (27A266a) and the iPhone 17 Pro simulator on iOS 26.5. Nine sample tests passed, and an unsigned iOS device build succeeded. These tests and the model-free launch/layout check do not validate actual on-device generation. Older declared core deployment targets are not device-qualified by this run.

**Physical-device validation is pending at the owner's request.** The remaining smoke check is the walkthrough above on an eligible iPhone with real generation, plus one observation of combined app/model memory and first-response latency in Xcode. Record the device, OS, build configuration, NovaContext revision and resolved NovaGraph revision. No physical-model success or performance claim is made yet.

API references: [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession).
