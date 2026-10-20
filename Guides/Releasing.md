# Releasing NovaContext

The v0.1.0 candidate is prepared locally. The intended public repository is `rhindsntc/NovaContext`; creation, pushes, tags and a GitHub release have not happened as part of local preparation.

## Verify the source candidate

From a clean release checkout:

```sh
swift build
swift test
swift build -c release
git diff --check
```

Review the package manifest, license, README, changelog, release notes, compatibility guide and sample instructions. Keep the core Swift tools 6.0 / iOS 16 / macOS 13 floors, exact NovaGraph 1.0.0 dependency and the separate iOS 26+ sample requirements intact. Physical-device/model qualification stays pending until it is actually performed.

Use an archive of the exact candidate commit for a fresh downstream consumer with its own build directory. Compile public README examples and run remember → scoped recall → bounded composition → close/reopen, then edit/forget checks. Validate versioned SwiftPM resolution using a disposable local Git repository tagged `v0.1.0`; this proves local package/version mechanics, not access to an unpublished GitHub URL. Record the resolved NovaGraph version/revision.

## Publish when authorized

1. Merge the reviewed candidate into local `main`. Create the empty public `rhindsntc/NovaContext` repository without a generated README or license, add it as `origin`, and push `main`.
2. Wait for the existing **Swift package** GitHub Actions workflow to pass its Debug build, tests and Release build. Review failures before tagging.
3. Update preparation-only wording in README, changelog, release notes and compatibility using actual publication/check results. Update NovaGraph's web guide and generated data consistently. Do not claim a device check or hosted result that did not happen. Commit and push the final SDK documentation changes, review that committed revision, and wait for its hosted checks to pass before tagging it. Submit the matching NovaGraph documentation changes separately.
4. Tag that exact reviewed commit and push the tag:

```sh
git tag -a v0.1.0 -m "NovaContext v0.1.0"
git push origin v0.1.0
```

5. From a fresh downstream package, resolve `https://github.com/rhindsntc/NovaContext.git` with `exact: "0.1.0"` and the product `.product(name: "NovaContext", package: "novacontext")`. Build and run the public-API smoke against that remote tag. A local-tag check does not replace this remote check.
6. Create a draft GitHub release from the verified tag with `RELEASE_NOTES.md`, review it, then publish. Do not move an existing public tag to repair a release; use a new version for subsequent fixes.

The source archive should contain tracked package sources/tests, public guides, sample, workflow and license. It must exclude Git metadata, private planning/work logs, caches, database contents and generated signing/Xcode artifacts. The release notes must retain pending device/model qualification.
