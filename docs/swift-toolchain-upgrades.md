# Swift toolchain upgrades

Chickadee moves to each new Swift release on a schedule. A Routine starts the
work two times a year. This file is the runbook it follows, and it holds the
agent prompts.

The work is always two pull requests, in this order:

1. **Move the pins.** The toolchain version changes in every place that names
   it. Nothing else changes.
2. **Scan the new features.** The codebase adopts the features that correct a
   defect or delete hand-written code. It records the features it does not
   adopt, and the reason for each one.

Keep them separate. The pin move touches the build of every job. A red check on
a mixed pull request cannot tell you which half caused it.

The Swift 6.3 to 6.4 upgrade is the model. Read
[#1541](https://github.com/JimWallace/Chickadee/pull/1541) for the pin move and
[#1544](https://github.com/JimWallace/Chickadee/pull/1544) for the feature scan.

---

## The schedule

The Routine fires on 15 March and 15 September, at 09:00 Eastern (cron
`0 13 15 3,9 *`, UTC). Swift ships a release in approximately March and
approximately September. The Routine fires after the release, and after the
Docker images are usually available.

The Routine is `trig_019sGYKbtBnvE9pxg4LTqLpQ`, named "Swift toolchain upgrade
check (semi-annual)". It starts a new session on each fire, and it reports by
push and by email. Change the schedule or the prompt on the Routine itself. Do
not make a second Routine, because two of them will open two pull requests for
the same release.

A **minor** release (6.4 to 6.5, or 6.x to 7.0) starts the full two-pull-request
work.

A **patch** release (6.4.0 to 6.4.1) is a smaller job. The Docker tags
`swift:6.4-noble` and `swift-ci:6.4-noble` follow the patch automatically, and
`mirror-images.yml` refreshes them weekly. Only the sites that name the patch
number change: `wasm/wasm-sdk.pin`, the swiftly version in
`runner-wasm-vendor.yml`, and the SDK identifier in
`scripts/build-runner-wasm.sh`. There is no feature scan for a patch release.

If there is no new release, the Routine stops. It does not open a pull request.

---

## Step 0 — find out if there is a new version

Three conditions must be true before you start. Do not start the work if one of
them is false.

1. **The release exists.** Read <https://www.swift.org/install/linux/> and
   <https://github.com/swiftlang/swift/releases>. Get the exact version, for
   example `6.5.0`.
2. **The Docker images exist.** The `swift:<X.Y>-noble` tag must be on Docker
   Hub. This was the only thing that blocked #1541. The toolchain was released
   on 14 September and the images landed five days later.
3. **The WebAssembly SDK exists.** The bundle for the release must be published.
   Read <https://www.swift.org/documentation/articles/wasm-getting-started.html>
   for the URL and the checksum.

If the toolchain is out and the images are not, say so and stop. Do not build a
pull request that CI cannot run.

---

## Step 1 — move the pins

### Find every pin

Do not copy a list of files from this document. Find the pins in the tree:

```
grep -rn "6\.4" --include='*.yml' --include='Dockerfile' --include='*.sh' --include='*.pin' --include='Package.swift' . | grep -viE 'changelog|docs/archive'
```

The pins live in these places:

| Site | What it holds |
|---|---|
| `Package.swift` line 1 | the swift-tools-version |
| `Dockerfile` compile stage | `swift:<X.Y>-noble` |
| `.github/docker/ci-image/Dockerfile` | `BASE_IMAGE`, and the comment above it |
| `.github/workflows/mirror-images.yml` | the mirror source, the derived tag, the comments |
| 13 workflow files | approximately 20 job images, `swift:` and `swift-ci:` |
| `.github/workflows/runner-wasm-vendor.yml` | the swiftly version, twice |
| `wasm/wasm-sdk.pin` | the bundle URL and the checksum |
| `scripts/build-runner-wasm.sh` | the default SDK identifier |
| `scripts/ci-compose-env.sh` | the image names in the comments |

Leave these alone. They are records, not pins:

- `CHANGELOG.md` and `CHANGELOG-0.4.md`
- `docs/archive/` and any audit that describes a past state
- `wasm/Package.swift`, which declares tools version 6.0 and still resolves

Compute the wasm checksum from the artifact that you download. Do not copy a
number from a note.

### Traps that cost a day

**The first CI run fails, and that is expected.** The test jobs use
`swift-ci:<X.Y>-noble`. That tag does not exist in GHCR until
`mirror-images.yml` publishes it. The jobs start together, so all of the
container jobs fail at `docker pull ... manifest unknown`. Let the mirror job
finish, then re-run. #1541 hit this and the re-run was green.

**Vendor the browser wasm inside the pull request.** The vendor gate hashes
`scripts/build-runner-wasm.sh`. Your change edits that file, so a merge with no
vendored artifact makes `runner-wasm-vendor.yml` rebuild the artifact on `main`,
unattended, on a new SDK, after the review. Build it in the pull request,
run the browser tests against it, and regenerate `source.sha`.

**A link that succeeds can still give a broken binary.** #1522 shipped one.
Execute both products. `chickadee-server` must boot, read `AppConfig` and run
its migrations. `chickadee-runner` must print its argument help.

**Attribute a new build failure with a control.** Build the same product, on the
same machine, from unmodified `main`, on the old toolchain. A failure that also
happens there is not from the new toolchain.

**The distro stays where it is.** A Swift release often makes a new Ubuntu the
Docker `latest`. Do not take it in this pull request. The CI image and the
production image install seven grading interpreters. A distro change moves all
seven at the same time, and `default-jdk` changes its major version with no line
of code changing. The execution-path test suites skip when an interpreter is
absent. They do not fail. So the distro half of a mixed change fails silently.
Give the distro its own pull request.

**A changed build system can neutralise a flag without removing it.** Swift 6.4
made SwiftBuild the SwiftPM default. It orders the compiler command line
differently. `-Xswiftc` flags now come BEFORE each target's own
`swiftSettings`, so a target setting wins over the command line. The mutation
sweep used `-Xswiftc -no-warnings-as-errors` against the package's
`.treatAllWarnings(as: .error)`. After the move, that argument was still
accepted and still printed. It had no effect. The frontend command read
`-no-warnings-as-errors -warnings-as-errors -no-warnings-as-errors
-warnings-as-errors`. No job could see it, because the tree itself compiles
with no warnings. Only a mutated copy trips it, and that runs weekly. Six of
twelve shards died, three releases later. The demotion is a toolset now, which
wins under both build systems. `scripts/mutation-run.sh --check-build-flags`
proves it in five seconds.

Keep the shape, not the instance. A flag that overrides a build setting depends
on order. A build-system change re-orders it and says nothing. Such a flag needs
a check of its EFFECT, not of its presence.

**Look at the workarounds that the last upgrade added.** Swift 6.4 added two,
and both are still in the tree:

- the release build pins `--build-system native`, because the Swift Build
  engine drops `lib_FoundationICU.a` from the link line
- `chickadee-runner` links `-lcurl` explicitly, because 6.4 drops libcurl the
  same way

Try the build without each workaround on the new toolchain. If the link is
clean, delete the workaround and say so in the changelog fragment.
`--build-system native` is deprecated and prints a warning on every build.

---

## Step 2 — scan the new features

Start this after the pin pull request merges. The compiler must be the new one
before you can use a new feature.

### Find the feature list

- The release notes for the version, in the `swiftlang/swift` release
- <https://www.swift.org/swift-evolution/> filtered to that release
- The `CHANGELOG.md` of the toolchain repository
- The release notes for Swift Testing, Foundation and SwiftPM

Make the full list first. Then judge each item against the codebase.

### The bar for adoption

Adopt a feature for one of these reasons only:

- It **corrects a defect**. Async `defer` (SE-0493) and cancellation shields
  (SE-0504) fixed two real worker defects in #1544. One of them lost a
  student result for ten minutes.
- It **deletes hand-written code** that exists only to work around the absence
  of the feature. The move to swift-subprocess deleted three such sequences.
- It is **necessary**. Module selectors (SE-0491) were necessary, because
  `PersonalizationEvaluator` imports two modules that each declare a type with
  the name `Environment`.

Do not adopt a feature for style. A change with 19 call sites and no behaviour
change is noise in the history, and it makes every later `git blame` longer.

Look in these places first. They are where the last three upgrades found work:

- `Sources/Worker/` — concurrency, cancellation, process spawning
- `Sources/APIServer/Services/` — the same, on the server side
- `Sources/RunnerCore/` — ownership and performance features, if any apply.
  This target compiles to Embedded Swift and WebAssembly.
- `Tests/` — new Swift Testing traits. `scripts/no-new-xctest.sh` blocks XCTest.

**Never change a unit test without asking the maintainer first.** A signature
that follows a function turning `async` is not a change to a test. A changed
assertion is.

### Record what you do not adopt

The pull request body must name every feature you considered and did not use,
with the reason. #1544 does this in its last section. The next agent reads that
list and does not spend the time again.

---

## Verification

Run all of this on the new toolchain before you push. The container default
toolchain cannot read a newer tools-version manifest, so install the new one:

```
curl -O https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz
tar zxf swiftly-x86_64.tar.gz
./swiftly init -y --skip-install --quiet-shell-followup
. "$HOME/.local/share/swiftly/env.sh"
swiftly install 6.5.0
swiftly use 6.5.0
swift --version
```

The gauntlet:

| Check | Pass condition |
|---|---|
| `swift package resolve` | clean, and `Package.resolved` does not change |
| `swift build` | 0 warnings, 0 errors, under warnings-as-errors |
| `swift test` | 0 failures, and the count matches the count before the move |
| `scripts/lint.sh` | swift-format produces no diff |
| `scripts/swiftlint.sh` | 0 violations, under `--strict` |
| `scripts/check-guards.sh` | every fixture proves its guard |
| `scripts/mutation-run.sh --check-build-flags` | the sweep's warning demotion still takes effect |
| `scripts/check-styles.sh` | green, it runs the other guards |
| release link, both products | links, and both binaries execute |
| `scripts/build-runner-wasm.sh` | builds on the new Embedded SDK |
| `node --test Tests/BrowserRunnerJSTests/*.mjs` | the count matches the count before the move |

Record the numbers in the pull request body. A count that moves without a reason
is a finding.

Do not touch `VERSION`, `Sources/Core/ChickadeeVersion.swift` or `CHANGELOG.md`.
Add one fragment under `changelog.d/`.

---

## Agent prompts

The Routine sends the orchestrator prompt. The orchestrator does Step 0, then
gives one of the two prompts below to the agent that does the work. Fill in
every `<...>` field before you send a prompt.

### Prompt A — move the pins

```text
Move the Chickadee toolchain from Swift <OLD> to Swift <NEW>.

Read docs/swift-toolchain-upgrades.md first. It is the runbook for this job.
Follow Step 1 and the Verification section. Read PR #1541 for the last upgrade.

Scope: the toolchain pins only. Do not change the Ubuntu base image. Do not
adopt a language feature. Do not change a unit test.

Do this:
1. Find every pin with the grep in the runbook. Move each one to <NEW>.
   Leave the changelog and the archived docs alone.
2. Compute the WebAssembly SDK checksum from the artifact you download.
3. Try the release build without the --build-system native flag, and without
   the -Xlinker -lcurl flag. Delete a workaround that is no longer needed.
4. Build the browser wasm on the new Embedded SDK, run the browser tests
   against it, and regenerate source.sha. Do not leave this to the vendor job.
5. Run the whole verification gauntlet in the runbook, on the new toolchain.
   Install it with swiftly. Execute both release binaries.
6. Add one fragment under changelog.d/. Do not touch VERSION,
   ChickadeeVersion.swift or CHANGELOG.md.

Attribute any new build failure with a control: the same product, the same
machine, unmodified main, the old toolchain.

The first CI run will fail every container job at "manifest unknown". That is
the mirror bootstrap, not your change. Wait for mirror-images.yml, then re-run.

Commit to branch <BRANCH>. Open a draft pull request. The body must carry the
table of pins you moved, the verification numbers, and any workaround you added
or deleted, with the evidence. Write in ASD-STE100 English.
```

### Prompt B — scan the features

```text
Scan the Swift <NEW> release for features that Chickadee should adopt.

The toolchain moved in PR <PIN_PR>. Read docs/swift-toolchain-upgrades.md
Step 2 first. Read PR #1544 for the last scan, including its list of features
that were considered and rejected.

Do this:
1. Build the full list of language, standard library, Foundation, SwiftPM and
   Swift Testing changes in <NEW>. Give the proposal number for each one.
2. Judge each item against this codebase. Adopt an item only if it corrects a
   defect, deletes hand-written code that works around its absence, or is
   necessary. Do not adopt an item for style.
3. Make the changes that pass that bar. Keep each one small and explain it.
4. Run the whole verification gauntlet in the runbook, on the <NEW> toolchain.
5. Add one fragment under changelog.d/.

Rules:
- Never change a unit test without asking the maintainer first. A signature
  that follows a function turning async is not a change to a test.
- Do not import Vapor in Core.
- Do not add an environment variable.
- Run the ui-review agent if you touch Resources/Views, Public/styles.css or a
  page-wiring Public/*.js file. This scan usually touches none of them.

Commit to branch <BRANCH>. Open a draft pull request. The body must have a
section for the features you adopted, with the defect each one corrects, and a
section for every feature you rejected, with the reason. Write in ASD-STE100
English.
```

### The orchestrator prompt

The Routine holds this prompt. It is in the Routine, not in this file, so that a
fired session reads it without the repository. This copy is for reference.

```text
Semi-annual Swift toolchain check for Chickadee.

Read docs/swift-toolchain-upgrades.md. It is the runbook.

Do Step 0 first. Find the newest stable Swift release. Compare it with the
tools version on line 1 of Package.swift.

If there is no newer release, or the swift:<X.Y>-noble Docker image is not
published yet, report that and stop. Do not open a pull request.

If there is a newer minor release and the images are published:
1. Open a tracking issue for the upgrade.
2. Do the work in Prompt A in the runbook. Open the pull request as a draft.
   Drive it to green.
3. After that pull request merges, do the work in Prompt B.
4. Report both pull requests.

If the newer release is a patch release, move only the three sites that name
the patch number, as the runbook Schedule section says. There is no feature
scan for a patch release.

The Routine carries no connector grants. Load the GitHub tools with ToolSearch.
If they are absent, push the work to the branch and report that you could not
open the pull request. Do not stop with the work unpushed.
```

---

## History

| Version | Released | Pin pull request | Feature pull request |
|---|---|---|---|
| 6.4.0 | 2026-09-14 | [#1541](https://github.com/JimWallace/Chickadee/pull/1541) | [#1544](https://github.com/JimWallace/Chickadee/pull/1544) |

Add a row for each upgrade. The table shows the cadence that the project
actually keeps.
