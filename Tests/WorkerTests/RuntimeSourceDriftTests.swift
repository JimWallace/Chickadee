// Tests/WorkerTests/RuntimeSourceDriftTests.swift
//
// The runtime helpers the runner installs, and the two things that can still go
// wrong now that there is only one copy of them.
//
// WHAT THIS FILE USED TO BE. A line-by-line comparison between
// `Tools/runner-support/*` and a 2,223-line hand-typed mirror in
// `Sources/Worker/TestRuntimeSources.swift`, ignoring comments, per language.
// That mirror is gone — `Plugins/EmbedRunnerSupport` compiles the canonical
// files into the binary — so the comparison it made is not a test any more, it
// is an identity. What survives is the half that was never about drift.
//
// THE DIRECTION THAT ACTUALLY BROKE. `test_runtime.rkt` once existed on disk
// with nothing embedding it and nothing installing it, so every per-language
// assertion passed while a real helper never reached a grading workspace. That
// check is unchanged below, because the plugin cannot fix it: embedding a file
// is not the same as some language asking for it.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct RuntimeSourceDriftTests {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static func canonical(_ filename: String) throws -> String {
        try String(
            contentsOf: repoRoot().appendingPathComponent("Tools/runner-support/\(filename)"),
            encoding: .utf8)
    }

    /// Every language installs a runtime helper, and the bytes it installs are
    /// the canonical file's — exactly, not modulo comments.
    ///
    /// The old version of this compared code lines only, because the hand-typed
    /// mirror deliberately dropped some documentation. With the mirror gone the
    /// comparison can be exact, and an exact one is worth keeping even though
    /// it looks tautological: it is the only end-to-end proof that the plugin
    /// embedded the file the switch names, rather than an empty string or a
    /// stale copy from an earlier build.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageInstallsItsCanonicalHelpers(_ language: AssignmentLanguage) throws {
        let helpers = runtimeHelperFiles(for: language)
        // A language with no helpers would pass the loop vacuously, which is
        // the failure mode this file exists to prevent.
        #expect(!helpers.isEmpty, "\(language) installs no runtime helper at all")

        for (filename, installed) in helpers.sorted(by: { $0.key < $1.key }) {
            #expect(
                !installed.isEmpty,
                "\(language) installs \(filename) as an empty string — the plugin did not embed it")
            #expect(
                installed == (try Self.canonical(filename)),
                """
                What the runner installs as \(filename) is not Tools/runner-support/\(filename). \
                Nothing hand-maintains these any more, so this means the embedding itself is \
                wrong — check Plugins/EmbedRunnerSupport.
                """)
        }
    }

    /// The canonical directory holds no helper that nothing installs.
    ///
    /// The direction that actually broke, and the one the plugin does NOT
    /// cover: `EmbedRunnerSupport` embeds every `test_runtime.*` it finds, but
    /// embedding is not installing. A seventh language's helper can sit in the
    /// binary with no arm of `runtimeHelperFiles(for:)` naming it, and every
    /// other assertion here would still pass.
    @Test func everyCanonicalRuntimeHelperIsInstalledBySomeLanguage() throws {
        let directory = Self.repoRoot().appendingPathComponent("Tools/runner-support")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("test_runtime.") || $0 == "sitecustomize.py" }
        #expect(!onDisk.isEmpty, "found no canonical runtime helpers to check")

        let installed = Set(allRuntimeHelperFiles().keys)
        for filename in onDisk.sorted() {
            #expect(
                installed.contains(filename),
                """
                Tools/runner-support/\(filename) is a runtime helper that no language installs. \
                Add it to `runtimeHelperFiles(for:)` — until then a generated test that loads it \
                finds nothing in the grading workspace, and no other guard sees this.
                """)
        }
    }

    /// R's personalization primitives are the same source the SERVER's
    /// expression driver composes.
    ///
    /// THIS REPLACES A STRUCTURAL GUARANTEE, and only R needs it. `testRuntimeR`
    /// used to be assembled in Swift as `helpers +
    /// RPersonalizationRuntime.chickadeeSeedRSource + …`, so the grading runtime
    /// and the server driver could not compute a student's seed differently —
    /// they were the same bytes by construction. Reading the canonical file
    /// instead gives that up unless something checks it.
    ///
    /// What it guards is not cosmetic: if the two seeds diverge, the driver
    /// picks a student's inputs from one number while the test grading them
    /// reads another, so every per-student case fails for a reason that appears
    /// nowhere in the output.
    ///
    /// LUA AND OCTAVE ARE DELIBERATELY ABSENT. Their canonical helpers were
    /// never composed from Core — they mirror it — and they are already covered
    /// by something stronger than text matching:
    /// `LuaPersonalizationDriverTests.theDriverSeedEqualsTheGradingRuntimeSeed`
    /// and its Octave twin RUN both implementations on the same environment
    /// variable and compare the numbers. R has no such test, which is exactly
    /// why R is the language whose guarantee had to be replaced rather than
    /// merely inherited. An execution test for R would be strictly better than
    /// this one; this is the check that matches what was lost.
    @Test(arguments: [
        RPersonalizationRuntime.chickadeeSeedRSource,
        RPersonalizationRuntime.chickadeeInputsRSource,
    ])
    func rRuntimePrimitivesAppearInTheCanonicalHelper(_ coreSource: String) throws {
        // Whitespace-insensitive per line: the Swift constants are indented to
        // their literal and the canonical file to its own structure. Comments
        // are ignored for the same reason the old drift test ignored them — a
        // reworded sentence is not a behaviour change.
        func codeLines(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let canonical = codeLines(try Self.canonical("test_runtime.R")).joined(separator: "\n")
        let core = codeLines(coreSource).joined(separator: "\n")
        #expect(!core.isEmpty, "the Core constant is empty — the extraction is wrong, not the file")
        #expect(
            canonical.contains(core),
            """
            Tools/runner-support/test_runtime.R no longer contains the Core personalization \
            source it must share with the server's expression driver. A student's seed would be \
            computed one way by the driver that picks their inputs and another way by the test \
            that grades them.
            """)
    }
}
