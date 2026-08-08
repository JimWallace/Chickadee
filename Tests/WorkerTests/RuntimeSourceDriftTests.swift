import Core
import Foundation
import Testing

@testable import chickadee_runner

// Guards against the runtime helpers drifting between their copies:
//   * Tools/runner-support/<helper>            (canonical)
//   * Sources/Worker/TestRuntimeSources.swift  (native worker embeds these)
//   * Public/browser-runner.js                 (the browser runner embeds these)
//
// The Swift side is checked here against the canonical files; the JS side is
// checked by Tests/BrowserRunnerJSTests/runtime-drift.test.mjs.  Comparison is
// over executable code only — blank lines and full-line comments are ignored,
// since the embeds intentionally omit some documentation comments but MUST keep
// identical behaviour.
//
// WHY THIS WALKS `allCases` AND NAMES NO FILE. It used to be one hand-written
// `@Test` per language, five of them, and the header above listed the files by
// name. `Tools/runner-support/test_runtime.rkt` was added with no embed to drift
// from and no test to notice, and the suite stayed green through an entire
// release — a sixth language simply had one fewer test than the other five, and
// nothing said so. The set now comes from `runtimeHelperFiles(for:)`, which is
// exhaustive on `AssignmentLanguage`, so a language cannot be absent from this
// guard without failing to compile the thing it is absent from.
//
// The comment marker is per-language and read from `lineCommentLeader` for the
// same reason: `#` for Python and R, `--` for Lua, `%` for Octave, `//` for C++,
// `;` for Racket. A normalizer that only knew `#` would compare Lua's prose as
// if it were code — not wrong, exactly, but it would fail the suite over a
// reworded sentence and teach everyone to stop reading the diff.
@Suite struct RuntimeSourceDriftTests {

    private func rstrip(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev] == " " || s[prev] == "\t" { end = prev } else { break }
        }
        return String(s[..<end])
    }

    private func normalizedCode(_ src: String, comment: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter {
                let s = $0.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && !s.hasPrefix(comment)
            }
            .map { rstrip($0) }
            .joined(separator: "\n")
    }

    private static func canonical(_ relativePath: String) throws -> String {
        // .../Tests/WorkerTests/RuntimeSourceDriftTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every helper the runner installs matches the canonical copy a maintainer
    /// edits — for every language, discovered rather than listed.
    @Test(arguments: AssignmentLanguage.allCases)
    func runtimeHelpersMatchTheirCanonicalSource(_ language: AssignmentLanguage) throws {
        let helpers = runtimeHelperFiles(for: language)
        // A language with no helpers at all would pass this test vacuously,
        // which is the failure mode the whole file exists to prevent. Every
        // language's generated tests load a runtime; none is exempt.
        #expect(!helpers.isEmpty, "\(language) installs no runtime helper at all")

        for (filename, embedded) in helpers.sorted(by: { $0.key < $1.key }) {
            let canon = try Self.canonical("Tools/runner-support/\(filename)")
            #expect(
                normalizedCode(embedded, comment: language.lineCommentLeader)
                    == normalizedCode(canon, comment: language.lineCommentLeader),
                """
                The \(language) embed of \(filename) in \
                Sources/Worker/TestRuntimeSources.swift has drifted from \
                Tools/runner-support/\(filename). Re-sync both copies (and, for a helper \
                the browser runner also embeds, its literal in Public/browser-runner.js).
                """)
        }
    }

    /// The canonical directory holds no helper that nothing installs.
    ///
    /// The other direction of the same guard, and the direction that actually
    /// broke: `test_runtime.rkt` existed on disk with nothing embedding it, so
    /// every per-language assertion passed while a real helper never reached a
    /// grading workspace. Checking only embed→canonical cannot see that.
    @Test func everyCanonicalRuntimeHelperIsInstalledBySomeLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/runner-support")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: root.path)
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
}
