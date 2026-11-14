// Tests/APITests/PatternFamilies/TestScriptVariablePrependerEdgeTests.swift
//
// The `TestScriptVariablePrepender` branches that `RawScriptVariableInliningTests`
// does not reach: the two compiled languages that emit nothing, a banner that
// appears only inside a line, and an explicit section ID that overrides the
// suite entry's own section.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct TestScriptVariablePrependerEdgeTests {

    private let variables = [
        FamilyVariable(name: "n", value: .int(5)),
        FamilyVariable(name: "label", value: .string("bmi")),
    ]

    /// C++ and Java emit nothing, for the reasons in `emit`, and they agree
    /// with `supportsRawScriptInlining`.
    @Test(arguments: [AssignmentLanguage.cpp, .java])
    func compiledLanguagesEmitNoDeclarations(_ language: AssignmentLanguage) {
        #expect(TestScriptVariablePrepender.emit(variables, language: language).isEmpty)
        #expect(!TestScriptVariablePrepender.supportsRawScriptInlining(language))
    }

    @Test(arguments: [AssignmentLanguage.python, .r, .lua, .octave, .racket])
    func interpretedLanguagesEmitOneLinePerVariable(_ language: AssignmentLanguage) {
        let emitted = TestScriptVariablePrepender.emit(variables, language: language)
        #expect(emitted.split(separator: "\n").count == variables.count)
        #expect(TestScriptVariablePrepender.supportsRawScriptInlining(language))
    }

    @Test func emptyVariablesEmitAnEmptyString() {
        #expect(TestScriptVariablePrepender.emit([], language: .python).isEmpty)
    }

    /// The banner text quoted inside a line (here a string literal) is not a
    /// banner line, so the body is left alone.
    @Test func aBannerQuotedInsideALineIsNotStripped() {
        let banner = TestScriptVariablePrepender.rawScriptBannerComment(language: .python)
        let body = "print(\"\(banner)\")\nassert True\n"
        #expect(TestScriptVariablePrepender.stripExistingBlock(body) == body)
    }

    @Test func aBannerBlockAtTheEndOfTheFileIsRemoved() {
        let banner = TestScriptVariablePrepender.rawScriptBannerComment(language: .python)
        let body = "assert True\n\(banner)\nn = 5"
        #expect(TestScriptVariablePrepender.stripExistingBlock(body) == "assert True")
    }

    @Test func anExplicitSectionOverridesTheSuiteEntrysSection() {
        let manifest = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "publictest_a.py", sectionID: "s1")],
            language: .python,
            sections: [
                TestSuiteSection(id: "s1", name: "One", variables: [FamilyVariable(name: "x", value: .int(1))]),
                TestSuiteSection(id: "s2", name: "Two", variables: [FamilyVariable(name: "x", value: .int(2))]),
            ])
        let fromEntry = TestScriptVariablePrepender.applyForRawScript(
            filename: "publictest_a.py", content: "assert x\n", manifest: manifest)
        let explicit = TestScriptVariablePrepender.applyForRawScript(
            filename: "publictest_a.py", content: "assert x\n", manifest: manifest, explicitSectionID: "s2")
        #expect(fromEntry.contains("x = 1"))
        #expect(!fromEntry.contains("x = 2"))
        #expect(explicit.contains("x = 2"))
        #expect(!explicit.contains("x = 1"))
    }

    @Test func anUnknownSectionAddsNoSectionVariables() {
        let manifest = TestProperties(
            language: .python,
            sections: [TestSuiteSection(id: "s1", name: "One", variables: [FamilyVariable(name: "x", value: .int(1))])])
        let content = "assert True\n"
        #expect(
            TestScriptVariablePrepender.applyForRawScript(
                filename: "publictest_a.py", content: content, manifest: manifest, explicitSectionID: "missing")
                == content)
    }

    @Test(arguments: ["publictest_a.cpp", "publictest_a.java", "publictest_a.sh", "data.csv"])
    func aFileThatCannotHostABlockIsUnchanged(_ filename: String) {
        let manifest = TestProperties(
            language: .python, globalVariables: [FamilyVariable(name: "g", value: .int(3))])
        let content = "unchanged\n"
        #expect(
            TestScriptVariablePrepender.applyForRawScript(filename: filename, content: content, manifest: manifest)
                == content)
    }
}
