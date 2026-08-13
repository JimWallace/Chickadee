// Tests/WorkerTests/DotfileScriptNameAgreementTests.swift
//
// The two file-extension scanners must answer the same question the same way.
//
// `AssignmentLanguage.scriptExtension(ofPath:)` (Core) decides which
// interpreters a job REQUIRES, and so which runners `RunnerLanguageGate` will
// let claim it. `classifyScriptInterpreter` (RunnerCore) decides which
// interpreter a script is actually RUN with. They are separate implementations
// — RunnerCore cannot import Core — so nothing but a test holds them together,
// and this is that test.
//
// They disagreed on dotfiles: Core applied the classic rule (a base name
// beginning with `.` has no extension), RunnerCore rejected only a name whose
// ONLY dot was leading. So `.hidden.lua` required no Lua of a runner and was
// then dispatched to `lua` anyway — `exit 127` in front of a student, which is
// the exact failure the gate exists to prevent.
//
// This lives in WorkerTests because it is the only target that can see both.

import Core
import RunnerCore
import Testing

@Suite struct DotfileScriptNameAgreementTests {

    private static func manifest(script: String) -> TestProperties {
        TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: script)],
            timeLimitSeconds: 10
        )
    }

    /// A dotfile name carries no language to EITHER scanner.
    ///
    /// The pairing is the point: the first expectation is what the claim gate
    /// sees, the second is what the runner does with the file it claimed. A fix
    /// to one without the other reopens the gap.
    @Test(arguments: [".hidden.lua", "..R", ".quiet.rkt", ".inner.m", ".x.java"])
    func aDotfileNameIsLanguagelessToBothScanners(_ script: String) {
        #expect(
            AssignmentLanguage.languagesRequiredToGrade(manifest: Self.manifest(script: script))
                .isEmpty,
            "the capability gate thinks \(script) needs an interpreter")
        #expect(
            classifyScriptInterpreter(name: script, source: "") == .unknown,
            "the dispatcher would run \(script) under a language interpreter the gate never required"
        )
    }

    /// The ordinary case still works — this narrows dotfiles, it does not
    /// disable extension classification.
    @Test(arguments: [
        ("t.lua", ScriptInterpreter.lua), ("t.R", .rscript), ("t.rkt", .racket),
        ("t.m", .octave), ("t.java", .java), ("t.py", .python),
    ])
    func anOrdinaryNameStillClassifies(_ pair: (String, ScriptInterpreter)) {
        #expect(classifyScriptInterpreter(name: pair.0, source: "") == pair.1)
        #expect(
            !AssignmentLanguage.languagesRequiredToGrade(manifest: Self.manifest(script: pair.0))
                .isEmpty,
            "\(pair.0) stopped requiring an interpreter of the runner that claims it")
    }
}
