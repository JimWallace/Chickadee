---
name: upgrading-swift-toolchain
description: >
  Moves Chickadee to a new Swift release: the Docker images, the workflow
  images, Package.swift, the toolchain version that swiftly installs and the
  WebAssembly SDK, then a scan of the new language features. Use when a new
  Swift minor or patch release is out, when the semi-annual toolchain Routine
  fires, or when asked to bump, upgrade or pin the Swift version.
---

# Upgrading the Swift toolchain

The runbook is [docs/swift-toolchain-upgrades.md](../../../docs/swift-toolchain-upgrades.md).
It holds the pin table, the traps, the verification table and the agent
prompts. The Swift 6.3 to 6.4 upgrade is the model: #1541 moved the pins and
#1544 scanned the features.

## Which job is it

| Release | Work |
|---|---|
| minor (6.4 to 6.5, or 6.x to 7.0) | two pull requests: move the pins, then scan the features |
| patch (6.4.0 to 6.4.1) | one small pull request: only the three sites that name the patch number (below) |
| none | stop, and open no pull request |

Keep the two pull requests separate. A red check on a mixed pull request
cannot tell you which half caused it. Start the feature scan only after the pin
pull request merges.

## Workflow for a patch release

The `swift:<X.Y>-resolute` and `swift-ci:<X.Y>-resolute` tags follow the patch
on their own, and `Package.swift` does not change. Copy this checklist:

```
Patch progress:
- [ ] 1. The release and its WebAssembly SDK bundle are published
- [ ] 2. wasm/wasm-sdk.pin: the bundle URL, and a checksum from the download
- [ ] 3. runner-wasm-vendor.yml: the Swift version that swiftly installs
- [ ] 4. scripts/build-runner-wasm.sh: the default SDK identifier
- [ ] 5. Run the verification table, and add one changelog.d fragment
```

In step 3, change the toolchain version only. The swiftly installer itself
(`swiftly-<version>-<arch>.tar.gz` and its SHA-256) is a separate pin, which a
toolchain upgrade does not change.

## Workflow for a minor release

Copy this checklist and complete it in order:

```
Toolchain progress:
- [ ] 1. The release exists (swift.org and the swiftlang/swift releases)
- [ ] 2. The swift:<X.Y>-resolute image exists on Docker Hub
- [ ] 3. The WebAssembly SDK bundle for the release is published
- [ ] 4. Install the new toolchain locally with swiftly
- [ ] 5. Find every pin with grep, and move each one
- [ ] 6. Compute the wasm checksum from the file you downloaded
- [ ] 7. Run the full verification table, and record the counts
- [ ] 8. Add one changelog.d fragment, and open pull request 1
- [ ] 9. After it merges: list the new features, and judge each one
- [ ] 10. Open pull request 2, with a section for each rejected feature
```

**Steps 1 to 3.** If one of them is false, say so and stop. Do not open a pull
request that CI cannot run. The images were the only blocker for #1541: they
arrived five days after the toolchain.

**Step 5.** Do not copy the file list from the runbook. Search for the current
version in the tree, as §"Find every pin" shows. Leave `CHANGELOG*.md`,
`docs/archive/` and `wasm/Package.swift` alone: they are records, not pins.
Then read §"Traps that cost a day" before you push. Three of them catch
everyone: vendor the browser wasm inside the same pull request, expect the
first CI run to fail until the image mirror publishes, and keep `format-lint`
on the noble tag.

**Step 7.** Every row of §"Verification" must pass on the new toolchain. A test
count that moves without a reason is a finding.

**Step 9.** Adopt a feature only if it corrects a defect, deletes hand-written
code, or is necessary. Do not adopt a feature for style. Upcoming features are
the exception: turn on each one that needs only fix-its, in `Package.swift`
`sourceSettings` and in `scripts/check-runnercore-embedded.sh`.

## Rules

- Never change a unit test without asking the maintainer first. A signature
  that follows a function that became `async` is not a change to a test. A
  changed assertion is.
- Do not make a second Routine. The Routine named in the runbook already fires
  each March and September.
