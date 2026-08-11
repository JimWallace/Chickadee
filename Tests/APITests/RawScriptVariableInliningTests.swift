// Tests/APITests/RawScriptVariableInliningTests.swift
//
// Global + section inputs inlined into a HAND-WRITTEN test script, in every
// language.
//
// Two defects motivated these, and both were invisible to the coverage that
// existed — `PatternFamilyRendererRTests` exercised `.R`, `.py` and `.sh`, which
// is precisely the set where the bugs did not appear:
//
//   1. The banner above the inlined block was a hardcoded `#` line for every
//      language. `#` is a comment in Python, R, Octave and shell, and is Lua's
//      length operator, a Racket reader prefix and a C++ preprocessor
//      directive. A Lua or Racket assignment with global inputs plus a
//      hand-written test produced a file the interpreter refused to load. The
//      banner is also the strip sentinel, so re-saving compounded it.
//   2. `rawScriptOverlayWrites` picked the language with a hand-written switch
//      on `py`/`r` and `default: nil`, so the PUT /suite path silently skipped
//      four languages that the MCP and single-script paths served.
//
// The execution suite at the bottom is the part that would actually have caught
// (1): it writes the emitted file and runs it.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct RawScriptVariableInliningTests {

    private static let manifest = TestProperties(
        requiredFiles: [], testSuites: [], timeLimitSeconds: 10,
        globalVariables: [FamilyVariable(name: "threshold", value: .double(18.5))])

    /// A hand-written test filename in `language`, using the extension the
    /// runner dispatches on.
    private static func filename(for language: AssignmentLanguage) -> String {
        "publictest_x.\(language.sourceFileExtension)"
    }

    // MARK: - The banner is a comment in the script's own language

    /// The banner must be a COMMENT in the language it is written into. Asked
    /// of every language, so a seventh cannot inherit Python's `#`.
    @Test(arguments: AssignmentLanguage.allCases)
    func theBannerIsCommentedInTheScriptsOwnLanguage(_ language: AssignmentLanguage) {
        let banner = TestScriptVariablePrepender.rawScriptBannerComment(language: language)
        #expect(
            banner.hasPrefix(language.lineCommentPrefix),
            "\(language.displayName)'s banner does not open with its comment marker")
    }

    /// Python and R keep byte-identical output — `#` is their only comment
    /// marker, and every script already saved carries that exact line.
    @Test(arguments: [AssignmentLanguage.python, .r])
    func thePreviouslyCorrectLanguagesAreByteIdentical(_ language: AssignmentLanguage) {
        #expect(
            TestScriptVariablePrepender.rawScriptBannerComment(language: language)
                == "# === Chickadee inputs: name = value, prepended at save time. Do not edit. ===")
    }

    /// Octave used to be in the list above and moved deliberately.
    ///
    /// It was the one language with TWO answers in the tree: `lineCommentPrefix`
    /// said `#` and a second switch, `lineCommentLeader`, said `%`. Both parse
    /// in Octave, which is why they disagreed for four releases with nothing
    /// failing — the inputs file got `%`, this banner got `#`, and every other
    /// Octave byte the system emits (`test_runtime.m`, every generated case)
    /// got `%`. Collapsing the two onto `%` makes the banner agree with the
    /// rest of the corpus, and with the marker MATLAB also accepts.
    @Test func octaveUsesItsConventionalMarker() {
        #expect(
            TestScriptVariablePrepender.rawScriptBannerComment(language: .octave)
                == "% === Chickadee inputs: name = value, prepended at save time. Do not edit. ===")
    }

    /// The invariant the byte-identity assertion was really protecting: an
    /// Octave script already carrying the old `#` banner must still be
    /// recognised and stripped, so a save replaces the block instead of
    /// stacking a second one on top of it.
    ///
    /// It holds for a reason that predates this change — `allBannerComments`
    /// appends the legacy `#` spelling unconditionally, for the Lua and Racket
    /// scripts that were left with an un-strippable block. Asserted here
    /// because that is now the only thing standing between an emission change
    /// and a compounding file, and nothing said so.
    @Test func anOctaveScriptCarryingTheOldHashBannerIsStillStripped() {
        let legacy = """
            # === Chickadee inputs: name = value, prepended at save time. Do not edit. ===
            threshold = 1.0;
            body_line = 1;
            """
        let script = TestScriptVariablePrepender.prependToRawScript(
            legacy,
            variables: [FamilyVariable(name: "threshold", value: .double(18.5))],
            language: .octave)
        #expect(
            !script.contains("# === Chickadee inputs"),
            "the legacy # banner must be stripped, not left above the new % one")
        #expect(
            script.components(separatedBy: "=== Chickadee inputs").count == 2,
            "exactly one banner must survive a re-save")
        #expect(script.contains("18.5"), "the new value must be inlined")
    }

    // MARK: - Every language that can be inlined into, is

    /// The defect in `rawScriptOverlayWrites`: four languages fell to
    /// `default: nil` and received nothing.
    @Test(arguments: [AssignmentLanguage.python, .r, .lua, .octave, .racket])
    func aHandWrittenTestReceivesTheAssignmentsInputs(_ language: AssignmentLanguage) {
        let script = TestScriptVariablePrepender.applyForRawScript(
            filename: Self.filename(for: language), content: "body\n", manifest: Self.manifest)
        #expect(script.contains("18.5"), "\(language.displayName) got no inlined value")
        #expect(script.contains("threshold"))
        #expect(script.contains("body"), "the instructor's own content must survive")
    }

    /// C++ is the one language that declines, and not as a limitation: its
    /// graded scripts are `.sh` wrappers, so a bare `.cpp` in the suite is not
    /// a thing the runner executes and an inlined declaration would never be
    /// read. Inputs reach C++ through `_ck_inputs.hpp`.
    @Test(arguments: ["publictest_x.cpp", "publictest_x.h", "publictest_x.hpp"])
    func cppSourceIsLeftAlone(_ name: String) {
        #expect(
            TestScriptVariablePrepender.applyForRawScript(
                filename: name, content: "int main(){}\n", manifest: Self.manifest)
                == "int main(){}\n")
    }

    /// A shell script belongs to no language and is left alone — the universal
    /// test contract carries no language signal, deliberately.
    @Test func shellScriptsAreLeftAlone() {
        #expect(
            TestScriptVariablePrepender.applyForRawScript(
                filename: "publictest_x.sh", content: "echo hi\n", manifest: Self.manifest)
                == "echo hi\n")
    }

    // MARK: - Placement

    /// Racket declarations must land INSIDE the module, so the `#lang` line
    /// keeps line 1. This is stronger than the shebang rule it reuses: a
    /// `(define …)` above `#lang` is a read error, not a style problem.
    @Test func racketKeepsItsLangLineFirst() {
        let script = TestScriptVariablePrepender.applyForRawScript(
            filename: "publictest_x.rkt",
            content: "#lang racket\n(displayln threshold)\n", manifest: Self.manifest)
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "#lang racket", "#lang must stay on line 1")
        let defineIndex = lines.firstIndex { $0.contains("(define threshold") }
        #expect(defineIndex != nil, "the inlined define is missing")
        #expect((defineIndex ?? 0) > 0, "the define must follow #lang, not precede it")
    }

    @Test func aShebangKeepsLineOne() {
        let script = TestScriptVariablePrepender.applyForRawScript(
            filename: "publictest_x.py",
            content: "#!/usr/bin/env python3\nprint(threshold)\n", manifest: Self.manifest)
        #expect(script.hasPrefix("#!/usr/bin/env python3\n"))
    }

    // MARK: - Idempotency and recovery

    /// Re-saving must not stack blocks — the banner is the strip sentinel, and
    /// a banner in the wrong comment syntax is one the stripper cannot find.
    @Test(arguments: [AssignmentLanguage.python, .r, .lua, .octave, .racket])
    func resavingReplacesTheBlockRatherThanStackingIt(_ language: AssignmentLanguage) {
        let name = Self.filename(for: language)
        let once = TestScriptVariablePrepender.applyForRawScript(
            filename: name, content: "body\n", manifest: Self.manifest)
        let twice = TestScriptVariablePrepender.applyForRawScript(
            filename: name, content: once, manifest: Self.manifest)
        #expect(once == twice, "\(language.displayName) stacked a second block on re-save")
    }

    /// A Lua or Racket script already carrying the broken `#` banner gets it
    /// removed on the next save. That is the only recovery path those files
    /// have, since the instructor cannot delete the block by hand without
    /// guessing where it ends.
    @Test(arguments: [AssignmentLanguage.lua, .racket])
    func theLegacyBrokenBannerIsStrippedOnResave(_ language: AssignmentLanguage) {
        let legacy = """
            # === Chickadee inputs: name = value, prepended at save time. Do not edit. ===
            threshold = 1.0

            body
            """
        let fixed = TestScriptVariablePrepender.applyForRawScript(
            filename: Self.filename(for: language), content: legacy, manifest: Self.manifest)
        #expect(
            !fixed.contains("# ==="),
            "\(language.displayName) kept a `#` banner its interpreter cannot read")
        #expect(fixed.contains("body"))
    }
}

/// Runs the emitted script for real, in every language whose interpreter is on
/// this machine.
///
/// The point of the suite: a `#`-prefixed banner in a Lua file is a *syntax
/// error*, and no amount of string assertion says so as plainly as a non-zero
/// exit. Interpreters absent from the host are skipped silently — the CI image
/// carries more of them than a dev box does.
@Suite(.serialized, .timeLimit(.minutes(3))) struct RawScriptVariableInliningExecutionTests {

    /// A script that exits 0 only if the inlined `threshold` is readable and
    /// carries the value that was inlined.
    private static func probeBody(for language: AssignmentLanguage) -> String {
        switch language {
        case .python: return "import sys\nsys.exit(0 if threshold == 18.5 else 1)\n"
        case .r: return "if (threshold != 18.5) quit(status = 1)\n"
        case .lua: return "os.exit(threshold == 18.5 and 0 or 1)\n"
        case .octave: return "if (threshold != 18.5)\n  exit(1);\nend\n"
        case .racket:
            return "#lang racket\n(exit (if (= threshold 18.5) 0 1))\n"
        case .cpp, .java:
            // Both decline inlining by design, so there is nothing to execute —
            // C++ because a bare `.cpp` is never run, Java because a `.java`
            // file has no top-level statement position to inline into. See
            // `TestScriptVariablePrepender.supportsRawScriptInlining`.
            return ""
        }
    }

    private static func interpreter(for language: AssignmentLanguage) -> [String]? {
        switch language {
        case .python: return ["python3"]
        case .r: return ["Rscript"]
        case .lua: return ["lua"]
        case .octave: return ["octave-cli", "--no-gui", "--quiet"]
        case .racket: return ["racket"]
        case .cpp, .java: return nil
        }
    }

    private static func isAvailable(_ command: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", command]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    @Test(arguments: AssignmentLanguage.allCases)
    func theInlinedScriptRunsInItsOwnInterpreter(_ language: AssignmentLanguage) throws {
        guard let argv = Self.interpreter(for: language), let command = argv.first else { return }
        // Not "expected on this platform" as a failure: a dev box has neither
        // octave-cli nor racket, and a silent skip is the house rule for that.
        guard Self.isAvailable(command) else { return }

        let manifest = TestProperties(
            requiredFiles: [], testSuites: [], timeLimitSeconds: 10,
            globalVariables: [FamilyVariable(name: "threshold", value: .double(18.5))])
        let name = "publictest_probe.\(language.sourceFileExtension)"
        let source = TestScriptVariablePrepender.applyForRawScript(
            filename: name, content: Self.probeBody(for: language), manifest: manifest)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck_inline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(name)
        try source.write(to: path, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv + [path.path]
        proc.currentDirectoryURL = dir
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        #expect(
            proc.terminationStatus == 0,
            """
            The inlined \(language.displayName) script did not run cleanly \
            (exit \(proc.terminationStatus)). stderr:
            \(String(data: errData, encoding: .utf8) ?? "")
            Source:
            \(source)
            """)
    }
}
