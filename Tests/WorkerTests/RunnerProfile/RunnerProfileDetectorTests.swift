// Tests/WorkerTests/RunnerProfile/RunnerProfileDetectorTests.swift
//
// The version parse behind runner capability advertisement.
//
// WHY THIS FILE EXISTS. `RunnerProfileDetector` had NO test of any kind, and
// `firstNumericVersion` — the function that decides whether a runner advertises
// a language at all — had zero coverage. That is where Racket was lost: the
// banner is `Welcome to Racket v8.10 [cs].`, the version token is letter-led,
// and the old prefix-only rule matched nothing. `detectVersion` returned nil,
// `racket` never entered `languageVersions`, and `RunnerLanguageGate` then
// refused EVERY runner for every Racket assignment — so the jobs queued forever
// with no error, no failed test and no log line. Instructor validation included.
//
// The conformance matrix's `everyLanguageProbeActuallyReportsAVersion` runs the
// real probe and asserts it EXITS 0, which `racket --version` does. Exit code
// and parse are different questions, and this file asks the second one.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct RunnerProfileDetectorTests {

    /// The real banner each interpreter prints, as observed. Pinned as data so
    /// a parser change is checked against every language at once rather than
    /// against whichever one someone had in mind.
    static let banners: [(AssignmentLanguage, String, String)] = [
        (.python, "Python 3.11.2", "3.11.2"),
        (.r, "R version 4.3.1 (2023-06-16) -- \"Beagle Scouts\"", "4.3.1"),
        (.lua, "Lua 5.4.4  Copyright (C) 1994-2022 Lua.org, PUC-Rio", "5.4.4"),
        (.octave, "GNU Octave, version 8.4.0", "8.4.0"),
        (.cpp, "g++ (Debian 12.2.0-14) 12.2.0", "12.2.0"),
        // The one that broke. Letter-led, and no other language's is.
        (.racket, "Welcome to Racket v8.10 [cs].", "8.10"),
        // `javac --version`, measured on 21.0.10. The OLD form is the trap
        // here, and it is Racket's trap wearing a different coat: `java
        // -version` prints `openjdk version "21.0.10" 2026-01-20` — to STDERR,
        // with the number QUOTED. The detector reads both streams and its
        // leading-non-digit drop eats the quote, so that form happens to parse
        // too; `--version` on the compiler is the answer that does not depend
        // on either tolerance, and `javac` is the binary a JRE-only host lacks.
        (.java, "javac 21.0.10", "21.0.10"),
    ]

    @Test func everyLanguagesRealBannerParses() {
        for (language, banner, expected) in Self.banners {
            let parsed = RunnerProfileDetector.firstNumericVersion(in: banner)
            #expect(
                parsed == expected,
                """
                \(language)'s banner "\(banner)" parsed as \(parsed ?? "nil"), expected \(expected). \
                A nil here means no runner advertises \(language), and every job in it queues \
                forever with nothing reporting why.
                """)
        }
    }

    /// The tokens that must NOT be mistaken for a version.
    ///
    /// Dropping leading non-digits is narrower than "any dotted number in the
    /// token", and these are the cases that keep it narrow: a copyright range
    /// and a release date have digits but no dot, and a domain has a dot but no
    /// digits. If any of them started matching, a runner would advertise a
    /// version like `1994` and an assignment's `minimumVersion` requirement
    /// would compare against nonsense.
    @Test(arguments: [
        "Copyright (C) 1994-2022", "(2023-06-16)", "Lua.org,", "PUC-Rio", "[cs].", "x86_64-linux",
    ])
    func nonVersionTokensDoNotParse(_ fragment: String) {
        #expect(
            RunnerProfileDetector.firstNumericVersion(in: fragment) == nil,
            "\"\(fragment)\" was read as a version")
    }

    /// A banner with no version at all yields nil rather than something.
    @Test func anEmptyOrVersionlessBannerIsNil() {
        #expect(RunnerProfileDetector.firstNumericVersion(in: "") == nil)
        #expect(RunnerProfileDetector.firstNumericVersion(in: "no version here") == nil)
    }

    /// The did-not-skip proof, run against the REAL interpreters.
    ///
    /// The pinned banners above are what was observed; this is what the machine
    /// actually prints today. Under `CI` every language must both answer its
    /// probe and have that answer parse — the two-step the original guard only
    /// checked the first half of. On a laptop a missing interpreter is not a
    /// defect, so absence is skipped there.
    @Test(.ciOnly) func everyProbeOutputParsesInCI() async {
        for language in AssignmentLanguage.allCases {
            let probe = language.interpreterProbe
            guard let run = try? await runTool([probe.command] + probe.versionArguments) else {
                Issue.record("\(language): could not spawn \(probe.command)")
                continue
            }
            let combined = run.stdout + "\n" + run.stderr
            #expect(
                RunnerProfileDetector.firstNumericVersion(in: combined) != nil,
                """
                \(language)'s probe (`\(probe.command) \
                \(probe.versionArguments.joined(separator: " "))`) printed a banner \
                `firstNumericVersion` cannot read, so no runner will advertise \(language) and \
                every job in it will queue forever. Banner was: \(combined.prefix(200))
                """)
        }
    }
}

/// The compile-and-exec capability probe.
///
/// It gates whether a runner advertises C++ at all, and `docs/cpp-support.md`
/// records it catching a real production case (a `noexec` work root at
/// v0.5.33) — and nothing tested it. Both directions matter: failing open
/// advertises a capability the host does not have and every C++ job dies at
/// `exec`; failing closed advertises nothing and every C++ job queues forever.
@Suite(.timeLimit(.minutes(2))) struct RunnerExecProbeTests {

    /// The probe program is answered per language, exhaustively — the guard
    /// against an eighth compiled language reaching the probe with C++'s source.
    @Test func onlyCppSuppliesAnExecProbeProgram() {
        for language in AssignmentLanguage.allCases {
            let program = RunnerProfileDetector.execProbeProgram(for: language)
            #expect(
                (program != nil) == language.descriptor.capabilityRequiresExecutableOutput,
                """
                \(language) disagrees with its descriptor: capabilityRequiresExecutableOutput \
                is \(language.descriptor.capabilityRequiresExecutableOutput) but the probe \
                program is \(program == nil ? "absent" : "present").
                """)
        }
    }

    /// A work root that permits exec advertises C++; the same probe against a
    /// directory it cannot write to does not.
    @Test(.requiresGpp) func theProbeAdvertisesCppOnlyWhenTheWorkRootCanRunABinary() async throws {
        let usable = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-execprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: usable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: usable) }

        let good = await RunnerProfileDetector(discoveryEnabled: true, workRoot: usable).detect()
        let goodProfile = try #require(good)
        #expect(
            goodProfile.languageVersions.contains { $0.language == "cpp" },
            "a usable work root did not advertise cpp: \(goodProfile.languageVersions)")

        // An unwritable work root cannot hold the probe, so the capability is
        // withheld — the fail-closed direction the gate depends on.
        let unusable = URL(fileURLWithPath: "/proc/chickadee-nonexistent-probe-root")
        let denied = await RunnerProfileDetector(discoveryEnabled: true, workRoot: unusable)
            .detect()
        let deniedProfile = try #require(denied)
        #expect(
            !deniedProfile.languageVersions.contains { $0.language == "cpp" },
            "cpp was advertised from a work root the probe could not use")
        // Everything else survives: the probe withholds one capability, not all.
        #expect(
            deniedProfile.languageVersions.contains { $0.language == "python" },
            "an unusable work root withheld python too, which needs no exec probe")
    }

}

// MARK: - RunnerProfileDetectorGapTests

// Closes mutation survivors in `Sources/Worker/RunnerProfileDetector.swift`
// carried by every sweep since Sources/Worker joined the scope (2026-08-26).
//
// WHY THIS FILE IS WORTH MORE THAN ITS SIZE. What this detector advertises is
// what `RunnerLanguageGate` matches a job against. A wrong answer here does not
// fail loudly: over-advertising sends jobs to a runner that cannot grade them,
// where they die at exit 127 and read as a broken test script, and
// under-advertising makes an assignment's jobs queue forever with no error and
// no failed test. That is the Racket defect the sibling
// RunnerProfileDetectorTests was written for, and these survivors sit on the
// same surface one layer down -- in whether a probe's result is believed at
// all, and in the order the answers are reported.
//
// Environment-shaped on purpose. These assertions compare the profile against
// what this host can actually run, computed here rather than assumed, so the
// suite means the same thing on a developer box, on the swift-ci image, and
// inside Muter's copy. An assertion hardcoding "numpy is present" would pass on
// CI and fail locally, which is how a test stops being run.
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

// Serialized because every test runs a full `detect()`, and each one spawns
// every probe at once. Four detections in parallel saturated the mutation
// sweep's runner until `import pandas` timed out, and the suite compared that
// timeout against an import that succeeded (2026-10-06 sweep, shards 2, 3, 10).
@Suite(.serialized, .timeLimit(.minutes(3))) struct RunnerProfileDetectorGapTests {

    /// True when `/usr/bin/env <command>` runs and exits 0 -- the same question
    /// `commandExists` asks, answered independently of the code under test.
    private static func hostHasCommand(_ command: String) async -> Bool {
        await toolIsAvailable("which", arguments: [command])
    }

    private static func detectProfile() async throws -> RunnerCapabilityProfile {
        try #require(await RunnerProfileDetector(discoveryEnabled: true).detect())
    }

    /// Survivor: `:99 RelationalOperatorReplacement` — the `<` ordering
    /// `languageVersions` → `>`.
    ///
    /// The profile is a wire payload the server stores and matches jobs
    /// against, so a stable order is what stops two runners with identical
    /// toolchains from advertising two different-looking profiles. The floor
    /// on the count is what keeps the assertion from passing vacuously: with
    /// one language there is no order to get wrong. Swift builds this test, so
    /// the floor is reachable wherever the suite runs at all.
    @Test func theProfileReportsLanguagesInAscendingOrder() async throws {
        let profile = try await Self.detectProfile()

        try #require(
            profile.languageVersions.count >= 2,
            "needs >= 2 languages for order to be observable; got \(profile.languageVersions.map(\.language))")

        #expect(profile.languageVersions.map(\.language) == profile.languageVersions.map(\.language).sorted())
    }

    /// Survivor: `:100 RelationalOperatorReplacement` — the `<` ordering
    /// `capabilities` → `>`.
    ///
    /// Same invariant as the languages above, but capabilities are a thinner
    /// set: a host with neither zsh nor an importable Python module advertises
    /// exactly one (`shell-bash`), and one element has no order. Rather than
    /// force a floor this host cannot meet, the check stands down silently —
    /// the repo's "expected on this platform" idiom — which means this survivor
    /// is only answered where the profile is rich enough to see it. Said
    /// plainly so nobody reads a pass here as coverage.
    @Test func theProfileReportsCapabilitiesInAscendingOrder() async throws {
        let profile = try await Self.detectProfile()
        guard profile.capabilities.count >= 2 else { return }

        #expect(profile.capabilities.map(\.name) == profile.capabilities.map(\.name).sorted())
    }

    /// Survivor: `:202 RelationalOperatorReplacement` — `commandExists` asking
    /// `runStatus(...) == 0` → `!= 0`.
    ///
    /// Inverted, the runner advertises exactly the shells it does NOT have.
    /// Compared against the host rather than hardcoded, so the test states the
    /// invariant ("advertised iff present") instead of a fact about one image.
    @Test func shellCapabilitiesMatchWhatTheHostActuallyHas() async throws {
        let profile = try await Self.detectProfile()
        let names = Set(profile.capabilities.map(\.name))

        for (command, capability) in [("bash", "shell-bash"), ("zsh", "shell-zsh")] {
            let advertised = names.contains(capability)
            let onHost = await Self.hostHasCommand(command)
            #expect(
                advertised == onHost,
                "\(capability) advertised: \(advertised), \(command) on host: \(onHost)")
        }
    }

    /// Survivor: `:198 RelationalOperatorReplacement` — `pythonImportAvailable`
    /// asking `runStatus(...) == 0` → `!= 0`.
    ///
    /// Inverted, the runner advertises precisely the Python modules it cannot
    /// import — the over-advertising direction, where a job that needs pandas
    /// is routed to a runner without it and dies mid-test.
    ///
    /// Only meaningful where python3 exists; where it does not, the detector
    /// never runs these probes and there is nothing to assert.
    @Test func pythonModuleCapabilitiesMatchWhatTheHostCanImport() async throws {
        let hasPython = await Self.hostHasCommand("python3")
        try #require(hasPython, "no python3 on this host")
        let profile = try await Self.detectProfile()
        let names = Set(profile.capabilities.map(\.name))

        for module in ["numpy", "pandas", "scipy", "matplotlib"] {
            let importable = await Self.hostCanImportPythonModule(module)
            #expect(
                names.contains(module) == importable,
                "\(module) advertised: \(names.contains(module)), importable on host: \(importable)")
        }
    }

    /// A module import loads far more than a `--version` banner, so its probe
    /// must not share the short cap. With one cap, a loaded host timed out on
    /// `import pandas` and the runner stopped advertising a module it had.
    @Test func moduleImportProbesOutlastVersionProbes() {
        #expect(RunnerProfileDetector.moduleImportTimeoutSeconds > RunnerProfileDetector.probeTimeoutSeconds)
    }

    private static func hostCanImportPythonModule(_ module: String) async -> Bool {
        await toolIsAvailable("python3", arguments: ["-c", "import \(module)"])
    }
}

// MARK: - RunnerProfileProbeTimeoutTests

// A capability probe that runs out of time is logged, with the command and
// the limit, before the detector gives up on it. The mutation sweep of
// 2026-10-13 (#2535) deleted that log call (`:285 RemoveSideEffects`) and
// nothing failed. The log line is the only trace of a probe that timed out:
// the profile just lacks the language, and `RunnerLanguageGate` then leaves
// every job that needs it in the queue with no error (see
// RunnerProfileDetectorGapTests).
//
// Protocol: docs/mutation-triage.md -- SURVIVED confirmed before, KILLED after.

@Suite(.timeLimit(.minutes(1))) struct RunnerProfileProbeTimeoutTests {

    @Test func aProbeThatRunsOutOfTimeIsLoggedAndYieldsNothing() async throws {
        let capture = RunnerLogCapture()
        let result = await RunnerLogCapture.$current.withValue(capture) {
            await RunnerProfileDetector(discoveryEnabled: true)
                .runProbe(command: "sleep", arguments: ["30"], timeoutSeconds: 0.2)
        }
        #expect(result == nil)

        let line = try #require(capture.capturedLines.first)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(payload["event"] as? String == "local_execution_error")
        #expect(payload["error_type"] as? String == "capability_detection_timeout")
        #expect(payload["error_message_summary"] as? String == "sleep 30")
        #expect(payload["timeout_seconds"] as? Double == 0.2)
    }
}

// MARK: - RunnerProfilePythonProbeTests

// The Python module probes (numpy, pandas, scipy, matplotlib) run exactly when
// the host has Python. The mutation sweep of 2026-09-22 (#1574) flipped the
// `==` in that rule to `!=` and nothing failed: every CI host has every
// interpreter, so "Python is present" and "some other language is present"
// are both true there. On a Python-only runner the flipped rule advertised no
// modules, and a job needing pandas would never be routed to it.

@Suite struct RunnerProfilePythonProbeTests {

    private static func version(_ language: AssignmentLanguage) -> LanguageVersion {
        LanguageVersion(language: language.capabilityName, version: "1.0")
    }

    @Test func aPythonOnlyHostProbesItsModules() {
        #expect(RunnerProfileDetector.probesPythonModules(given: [Self.version(.python)]))
    }

    @Test func aHostWithoutPythonDoesNotProbeThem() {
        #expect(!RunnerProfileDetector.probesPythonModules(given: [Self.version(.r), Self.version(.lua)]))
        #expect(!RunnerProfileDetector.probesPythonModules(given: []))
    }
}
