# Contributing to NovaContext

NovaContext is a small Swift package for explicit persistent memory and bounded context assembly. Keep changes focused; discuss new public APIs before implementing them.

## Build and test

Use Xcode 16+ / Swift 6.0+ on macOS. From the package root:

```sh
swift build
swift test --no-parallel
swift build -c release
```

The package pins published NovaGraph 1.0.0. `Package.resolved` is ignored for this library; downstream applications own their resolution files. Do not introduce local NovaGraph overrides into committed manifests.

The separate iOS 26+ sample requires Xcode 26+ and XcodeGen. Its [README](Examples/OnDeviceMemory/README.md#tests) explains simulator tests and the labelled model-free walkthrough; core tests do not require Apple Intelligence. Physical-device testing remains pending for this release.

## Propose a change

Use the [NovaContext repository](https://github.com/National-Technologies-Club/NovaContext) for focused issues and pull requests. Explain the behavior, why it helps an application, and how it was verified. Include a regression test for behavior changes, and keep README, usage/compatibility guides and changelog consistent with public API changes. Keep plans, work logs, build products, generated Xcode projects and signing settings out of commits.

The `main` branch requires a pull request, the GitHub Actions `package` check (Debug build, tests and Release build), and one approving code-owner review. [CODEOWNERS](.github/CODEOWNERS) assigns every path to `@rhindsntc` and `@engineering-ntc`; either eligible owner may approve, but authors cannot approve their own pull requests. Keep the branch up to date, resolve review threads, and obtain approval after the latest push. New reviewable changes dismiss prior approvals. Merge using squash or rebase to preserve linear history; direct pushes, force pushes, deletion and rule bypasses are blocked.

For bug reports include the NovaContext revision/version, resolved NovaGraph version, Xcode/Swift and OS versions, a small reproducer, and the actual error. Use synthetic examples; do not include application memory contents, credentials or private database files.
