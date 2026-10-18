import Core
import Foundation
import Testing

@testable import APIServer

// #1394: the custom-script scaffold chose its compile branch from
// `capabilityRequiresExecutableOutput`, which is true of C++ alone, so a Java
// author's scaffold ran `java solution.java` — single-file source mode, which
// cannot see a second file. The branch is keyed on
// `gradingCompilesBeforeRunning` now, with the exec fact choosing between the
// two compiled shapes.
@Suite(.timeLimit(.minutes(3))) struct TestScriptTemplatesCompileTests {

    @Test func javaScaffoldCompilesWithJavacThenRunsTheClass() {
        let java = shellTestScript(type: .commandOutput, language: .java)
        #expect(java.contains("javac -encoding UTF-8 -d . solution.java"))
        #expect(java.contains("ACTUAL=$(java -cp . solution 2>&1)"))
        #expect(java.contains("Compilation failed"))
        // The source-mode invocation is exactly what must be gone.
        #expect(!java.contains("java solution.java"))
        // And nothing of C++'s shape leaked across: no binary is exec'd.
        #expect(!java.contains("ck_solution"))
    }

    @Test func cppScaffoldStillCompilesToABinaryAndExecsIt() {
        let cpp = shellTestScript(type: .commandOutput, language: .cpp)
        #expect(cpp.contains("g++ -std=c++20 -O0 -o ./ck_solution solution.cpp"))
        #expect(cpp.contains("ACTUAL=$(./ck_solution 2>&1)"))
        #expect(!cpp.contains("javac"))
    }

    /// Every language takes the shape its descriptor facts select — asked of
    /// the facts, not of a list of names, so a new language is covered the day
    /// its descriptor exists.
    @Test(arguments: AssignmentLanguage.allCases)
    func theShapeFollowsTheDescriptorFacts(_ language: AssignmentLanguage) {
        let script = shellTestScript(type: .commandOutput, language: language)
        let d = language.descriptor
        let runsDirectly = script.contains(
            "ACTUAL=$(\(d.scriptRunCommand) solution.\(d.sourceFileExtension) 2>&1)")
        let compiles = script.contains("Compilation failed")
        #expect(runsDirectly == !d.gradingCompilesBeforeRunning)
        #expect(compiles == d.gradingCompilesBeforeRunning)
        if d.gradingCompilesBeforeRunning {
            #expect(script.contains(d.interpreterProbe.command))
            #expect(script.contains("./ck_solution") == d.capabilityRequiresExecutableOutput)
        }
    }
}
