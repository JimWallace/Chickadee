import Core
import Foundation
import Testing

@testable import APIServer

/// The manifest rules every authoring door shares (#1713): each rule, the
/// order the first one is reported in, and that an edit is refused only for
/// the incoherence it introduces.
@Suite struct ManifestCoherenceTests {
    private func manifest(
        gradingMode: GradingMode = .worker, submissionMode: SubmissionMode = .notebook,
        graderOnlyFiles: [String] = [], activity: ClassActivity? = nil, language: AssignmentLanguage? = nil
    ) -> TestProperties {
        var props = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")], language: nil)
        props.gradingMode = gradingMode
        props.submissionMode = submissionMode
        props.graderOnlyFiles = graderOnlyFiles
        props.activity = activity
        props.language = language
        return props
    }

    private func json(_ props: TestProperties) throws -> String {
        try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    @Test func aCoherentManifestBreaksNoRule() {
        #expect(ManifestCoherence.violations(in: manifest()).isEmpty)
        #expect(ManifestCoherence.violation(in: manifest(gradingMode: .browser)) == nil)
        #expect(ManifestCoherence.violation(in: manifest(submissionMode: .uploadOnly, language: .cpp)) == nil)
    }

    @Test func eachRuleReportsItsDoorsSentence() {
        #expect(
            ManifestCoherence.violation(in: manifest(gradingMode: .browser, submissionMode: .uploadOnly))
                == uploadModeGradingConflictMessage)
        #expect(
            ManifestCoherence.violation(in: manifest(gradingMode: .browser, graderOnlyFiles: ["key.txt"]))
                == graderOnlyGradingConflictMessage)
        #expect(
            ManifestCoherence.violation(
                in: manifest(gradingMode: .browser, activity: ClassActivity(kind: .kingOfTheHill)))
                == activityOpponentGradingConflictMessage)
        #expect(
            ManifestCoherence.violation(in: manifest(submissionMode: .notebook, language: .cpp))
                == requiresUploadOnlyMessage(.cpp))
    }

    @Test func everyBrokenRuleIsListedInOrder() {
        let broken = manifest(
            gradingMode: .browser, submissionMode: .notebook, graderOnlyFiles: ["key.txt"],
            activity: ClassActivity(kind: .kingOfTheHill), language: .java)
        #expect(
            ManifestCoherence.violations(in: broken) == [
                graderOnlyGradingConflictMessage, activityOpponentGradingConflictMessage,
                requiresUploadOnlyMessage(.java),
            ])
    }

    @Test func anEditIsRefusedForTheIncoherenceItIntroduces() throws {
        let stored = try json(manifest(submissionMode: .uploadOnly))
        #expect(
            ManifestCoherence.violation(introducedBy: { $0.gradingMode = .browser }, in: stored)
                == uploadModeGradingConflictMessage)
        #expect(ManifestCoherence.violation(introducedBy: { $0.gradingMode = .worker }, in: stored) == nil)
    }

    @Test func anEditIsNotRefusedForAnIncoherenceItInherits() throws {
        // A legacy manifest that already breaks the language rule can still
        // change its grading mode, and can be edited toward coherence.
        let stored = try json(manifest(submissionMode: .notebook, language: .cpp))
        #expect(ManifestCoherence.violation(introducedBy: { $0.gradingMode = .browser }, in: stored) == nil)
        #expect(ManifestCoherence.violation(introducedBy: { $0.submissionMode = .uploadOnly }, in: stored) == nil)
        #expect(ManifestCoherence.violation(introducedBy: { _ in }, in: "not json") == nil)
    }
}
