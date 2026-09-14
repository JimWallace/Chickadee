// Tests/APITests/ManifestRebuildPreservingTests.swift
//
// `makeWorkerManifestJSON(preserving:...)` exists because the base builder
// writes a fresh dict and every hand-threaded rebuild eventually forgot a
// field. This pins that a rebuild through the overload carries the fields
// that were each lost once.

import Core
import Testing

@testable import APIServer

@Suite struct ManifestRebuildPreservingTests {
    @Test func rebuildCarriesEveryPreservedField() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "publictest_a.sh", tier: "public", order: 1,
                    dependsOn: [], points: 2, displayName: "A")
            ],
            includeMakefile: true,
            gradingMode: "browser",
            submissionMode: "uploadOnly",
            requiredFiles: ["main.py"],
            timeLimitSeconds: 42,
            starterNotebook: "lab.ipynb",
            sections: [TestSuiteSection(id: "s1", name: "Warm-up")],
            globalVariables: [FamilyVariable(name: "n", value: .int(3))],
            datasets: [],
            language: nil,
            languageDeclared: true,
            minimumRunnerVersion: "0.5.100"
        )
        let props = try #require(decodeManifest(fromJSON: original))

        let rebuilt = try makeWorkerManifestJSON(preserving: props, testSuites: [], language: props.language)
        let after = try #require(decodeManifest(fromJSON: rebuilt))

        #expect(after.testSuites.isEmpty)
        #expect(after.makefile != nil)
        #expect(after.gradingMode == props.gradingMode)
        #expect(after.submissionMode == props.submissionMode)
        #expect(after.requiredFiles == ["main.py"])
        #expect(after.timeLimitSeconds == 42)
        #expect(after.starterNotebook == "lab.ipynb")
        #expect(after.sections.map(\.id) == ["s1"])
        #expect(after.globalVariables.map(\.name) == ["n"])
        #expect(after.language == nil)
        #expect(after.languageDeclared == true)
        #expect(after.minimumRunnerVersion == "0.5.100")
    }

    @Test func rebuildReplacesOnlyWhatTheCallerPasses() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [], includeMakefile: false,
            sections: [TestSuiteSection(id: "s1", name: "Warm-up")],
            language: .r, languageDeclared: true)
        let props = try #require(decodeManifest(fromJSON: original))

        let rebuilt = try makeWorkerManifestJSON(
            preserving: props, testSuites: [],
            sections: [TestSuiteSection(id: "s2", name: "Main")],
            language: .lua)
        let after = try #require(decodeManifest(fromJSON: rebuilt))
        #expect(after.sections.map(\.id) == ["s2"])
        #expect(after.language == .lua)
        #expect(after.languageDeclared == true)
    }
}
