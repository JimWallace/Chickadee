// Tests/WorkerTests/RunnerProfileDetectorGapTests.swift
//
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

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct RunnerProfileDetectorGapTests {

    /// True when `/usr/bin/env <command>` runs and exits 0 -- the same question
    /// `commandExists` asks, answered independently of the code under test.
    private static func hostHasCommand(_ command: String) async -> Bool {
        return await toolIsAvailable("which", arguments: [command])
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

    private static func hostCanImportPythonModule(_ module: String) async -> Bool {
        return await toolIsAvailable("python3", arguments: ["-c", "import \(module)"])
    }
}
