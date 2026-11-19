// Tests/APITests/Assignments/ManifestJSONFallbackTests.swift
//
// The manifest helpers in `ManifestJSON.swift` read a stored manifest string
// and either answer a question about it or rebuild it. Two kinds of path had
// no test: a stored manifest that does not decode, and a mode string that is
// not a `GradingMode` or a `SubmissionMode`. An unreadable manifest must give
// the "nothing here" answer and never a rebuilt manifest. An unknown mode must
// be refused by name, not stored.

import Core
import Testing

@testable import APIServer

@Suite struct ManifestJSONFallbackTests {

    private let unreadable = "{ this is not a manifest"

    private func entry(_ script: String) -> ConfiguredSuiteEntry {
        ConfiguredSuiteEntry(
            script: script, tier: "public", order: 1, dependsOn: [], points: 1, displayName: nil)
    }

    /// The name and reason of an `AppError.invalidParameter`, or nil for any
    /// other error.
    private func invalidParameter(_ error: any Error) -> (name: String, reason: String)? {
        guard case .invalidParameter(let name, let reason) = error as? AppError else { return nil }
        return (name, reason)
    }

    // MARK: - A manifest that does not decode

    @Test func anUnreadableManifestAnswersEveryQueryWithItsEmptyValue() throws {
        #expect(manifestDependents(manifestJSON: unreadable, filename: "a.py").isEmpty)
        #expect(generatedByFamilyID(manifestJSON: unreadable, filename: "a.py") == nil)
        #expect(try setupHasAnyTestEntries(manifestJSON: unreadable) == false)
    }

    @Test func anUnreadableManifestIsNotRebuilt() {
        // Nil, not a fresh manifest: a rebuild from nothing would drop every
        // field the stored manifest held.
        #expect(updateManifestAddingScript(manifestJSON: unreadable, entry: entry("a.py")) == nil)
        #expect(updateManifestRemovingScript(manifestJSON: unreadable, filename: "a.py") == nil)
    }

    @Test func aReadableManifestIsRebuilt() throws {
        let manifest = try makeWorkerManifestJSON(testSuites: [entry("a.py")], includeMakefile: false, language: nil)
        #expect(try setupHasAnyTestEntries(manifestJSON: manifest))

        let added = try #require(updateManifestAddingScript(manifestJSON: manifest, entry: entry("b.py")))
        #expect(decodeManifest(fromJSON: added)?.testSuites.map(\.script) == ["a.py", "b.py"])

        let removed = try #require(updateManifestRemovingScript(manifestJSON: manifest, filename: "a.py"))
        #expect(try setupHasAnyTestEntries(manifestJSON: removed) == false)
    }

    // MARK: - Unknown modes

    @Test func anUnknownGradingModeIsRefusedByName() throws {
        let error = #expect(throws: (any Error).self) {
            try makeWorkerManifestJSON(
                testSuites: [], includeMakefile: false, gradingMode: "server", language: nil)
        }
        let refusal = try #require(error.flatMap(invalidParameter))
        #expect(refusal.name == "gradingMode")
        #expect(refusal.reason == "Unknown grading mode \"server\".")
    }

    @Test func anUnknownSubmissionModeIsRefusedByName() throws {
        let error = #expect(throws: (any Error).self) {
            try makeWorkerManifestJSON(
                testSuites: [], includeMakefile: false, submissionMode: "both", language: nil)
        }
        let refusal = try #require(error.flatMap(invalidParameter))
        #expect(refusal.name == "submissionMode")
        #expect(refusal.reason == "Unknown submission mode \"both\".")
    }

    @Test func everyKnownModeIsAccepted() throws {
        for grading in GradingMode.allCases {
            for submission in SubmissionMode.allCases {
                let json = try makeWorkerManifestJSON(
                    testSuites: [], includeMakefile: false, gradingMode: grading.rawValue,
                    submissionMode: submission.rawValue, language: nil)
                let props = try #require(decodeManifest(fromJSON: json))
                #expect(props.gradingMode == grading)
                #expect(props.submissionMode == submission)
            }
        }
    }

    // MARK: - Rebuilding a draft

    @Test func aDraftRebuildRefusesAnUnknownGradingModeForANotebookLanguage() throws {
        let draft = try #require(
            decodeManifest(
                fromJSON: try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, language: .python)))
        let error = #expect(throws: (any Error).self) {
            try rebuildDraftManifestJSON(
                draft, testSuites: [], includeMakefile: false, gradingMode: "server",
                starterNotebook: "assignment.ipynb")
        }
        let refusal = try #require(error.flatMap(invalidParameter))
        #expect(refusal.name == "gradingMode")
    }

    @Test func aDraftRebuildForAnUploadOnlyLanguageIgnoresTheGradingModeField() throws {
        // An upload-only language is always graded by the worker, so the form's
        // grading mode is not read and a bad value is not an error.
        let draft = try #require(
            decodeManifest(
                fromJSON: try makeWorkerManifestJSON(
                    testSuites: [], includeMakefile: false, submissionMode: "uploadOnly", language: .cpp)))
        let json = try rebuildDraftManifestJSON(
            draft, testSuites: [], includeMakefile: false, gradingMode: "server",
            starterNotebook: "assignment.ipynb")
        let props = try #require(decodeManifest(fromJSON: json))
        #expect(props.gradingMode == .worker)
        #expect(props.submissionMode == .uploadOnly)
        #expect(props.language == .cpp)
    }
}
