# Releasing NovaContext

NovaContext source and releases live in [National-Technologies-Club/NovaContext](https://github.com/National-Technologies-Club/NovaContext). The first source release is v0.1.0. Physical-device and real-model qualification remain pending until those checks are actually performed.

## Verify the source candidate

From a clean release checkout:

```sh
swift build
swift test --no-parallel
swift build -c release
git diff --check
```

Review the manifest, license, README, changelog, release notes, compatibility guide and sample instructions. Keep the core Swift tools 6.0 / iOS 16 / macOS 13 floors, exact NovaGraph 1.0.0 dependency and separate iOS 26+ sample requirements intact. Compile the public README examples in a fresh downstream consumer with its own build directory, exercising remember → scoped recall → bounded composition → close/reopen and edit/forget behavior. Record the exact source and resolved dependency revisions.

A disposable local Git repository can validate versioned SwiftPM resolution before publication. This verifies local package/version mechanics; it does not replace installing from the actual GitHub tag.

## Publish an authorized release

1. Merge the reviewed release changes into local `main`. Confirm `git remote get-url origin` is `https://github.com/National-Technologies-Club/NovaContext.git`.
2. Update versioned installation instructions, changelog, release notes and compatibility with accurate evidence. Commit and push the final SDK revision, review it, and require its **Swift package** GitHub Actions workflow to pass Debug build, tests and Release build before tagging. Update NovaGraph's web guide/generated data separately. Do not infer device or hosted results.
3. Tag that exact committed, pushed and checked revision. Use a new version for each release; this example shows the first release's version:

```sh
NOVACONTEXT_RELEASE_VERSION=v0.1.0
git tag -a "$NOVACONTEXT_RELEASE_VERSION" -m "NovaContext $NOVACONTEXT_RELEASE_VERSION"
git push origin "$NOVACONTEXT_RELEASE_VERSION"
```

4. Resolve the actual remote tag from a fresh downstream package using `https://github.com/National-Technologies-Club/NovaContext.git`, the intended exact version, and `.product(name: "NovaContext", package: "novacontext")`. Build and run the public-API smoke. Record both package pins. Never move an existing public tag to repair a failure; use a new version for subsequent fixes.
5. Create a draft GitHub release from the verified tag using `RELEASE_NOTES.md`, review the notes and any source assets, then publish. Confirm its tag and commit match the checked revision.

Source archives contain tracked package sources/tests, public guides, sample, workflow and license. Exclude Git metadata, private work logs, caches, databases and generated signing/Xcode artifacts. Keep pending device/model qualification visible in the release notes.
