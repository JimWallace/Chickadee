// Tests/WorkerTests/GeneratedScriptDispatchTests.swift
//
// A language's generated scripts must actually DISPATCH — the runbook's
// compiler-invisible item 9, and the guard that would have caught Racket's F1
// the moment its descriptor literal landed.
//
// WHY IT IS A TEST AND NOT A COMPILE ERROR. `classifyScriptInterpreter` lives in
// `RunnerCore`, which the browser compiles to wasm and which therefore has NO
// dependency on `Core` — so it cannot reach `AssignmentLanguage` to iterate, and
// the dependency direction forbids the obvious fix. `Worker` depends on both,
// which is why this lives here.
//
// What went wrong without it: Racket's generated `.rkt` had no
// `ScriptInterpreter` case and no extension arm, so it classified `.unknown`,
// fell through to the `/bin/sh` fallback, and exited 2 on its own leading `;`.
// Every generated Racket test reported `error`, in the only grading path an
// upload-only language has — and every other language's rows in the dispatch
// fixture still passed.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct GeneratedScriptDispatchTests {

    /// The interpreter each language's generated scripts must reach.
    ///
    /// EXHAUSTIVE, so a seventh language has to state its answer here too —
    /// which is as close to compile-forced as this can get given that the
    /// classifier itself cannot see `AssignmentLanguage`.
    ///
    /// C++ is the deliberate exception and the reason this maps to a command
    /// rather than asserting "not the shell fallback": its generated case IS a
    /// POSIX shell wrapper (heredoc C++ source → g++ → run the binary), so it
    /// dispatches as shell ON PURPOSE. `.sh` must keep carrying no language
    /// signal, or every hand-written shell suite in every course would start
    /// sniffing as C++.
    static func expectedInterpreter(for language: AssignmentLanguage) -> String {
        switch language {
        case .python: return "python3"
        case .r: return "Rscript"
        case .lua: return "lua"
        case .octave: return "octave-cli"
        case .racket: return "racket"
        case .cpp: return "sh"
        }
    }

    /// A file named the way this language's generated tests are named, carrying
    /// a first line shaped the way they really begin, dispatches to that
    /// language's interpreter.
    ///
    /// The leading-comment line matters and is not decoration: Racket's
    /// generated tests open with `; Test: …`, which is what defeated the
    /// shebang check and the Python content sniff on the way to `/bin/sh`.
    @Test(arguments: AssignmentLanguage.allCases)
    func generatedScriptsDispatchToTheirOwnInterpreter(_ language: AssignmentLanguage) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ck-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let filename = "publictest_fam_01.\(language.generatedScriptExtension)"
        let url = dir.appendingPathComponent(filename)
        // A comment in the language's own leader, so nothing is classified by
        // accident of a shebang the real generated files do not carry.
        try "\(language.lineCommentLeader) Test: generated\n".write(
            to: url, atomically: true, encoding: .utf8)

        let invocation = scriptInvocation(for: url)
        let expected = Self.expectedInterpreter(for: language)
        // Two invocation shapes: `envInvocation` runs /usr/bin/env with the
        // interpreter as the first argument; `shInvocation` runs /bin/sh
        // directly with the script as its only argument. Read whichever names
        // the interpreter.
        let executable = invocation.executableURL.lastPathComponent
        let actual = executable == "env" ? (invocation.arguments.first ?? executable) : executable
        #expect(
            actual == expected,
            """
            A generated \(language) test (\(filename)) dispatches to `\(actual)`, expected \
            `\(expected)`. If this is the `/bin/sh` fallback, the language has no \
            ScriptInterpreter case and every generated test will report `error` at grade time.
            """)
    }

    /// `.sh` still carries no language signal.
    ///
    /// The other half of the C++ exception: its generated wrapper must dispatch
    /// as shell, and so must every hand-written `.sh` suite that predates any
    /// of this.
    @Test func shellScriptsStayLanguageless() {
        #expect(AssignmentLanguage(scriptExtension: "sh") == nil)
    }
}
