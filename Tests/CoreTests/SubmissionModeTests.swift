// Tests/CoreTests/SubmissionModeTests.swift
//
// Pins the submissionMode manifest field: Codable back-compat (every manifest
// written before the field existed decodes to .notebook), the round-trip, the
// runnerSanitized() pass-through, and — the load-bearing part —
// effectiveGradingMode, which is what keeps an upload-only assignment on the
// native worker even if an imported bundle or hand-crafted zip stores the
// incoherent upload + browser combination.

import Foundation
import Testing

@testable import Core

@Suite struct SubmissionModeTests {

    /// Every manifest on disk today predates the field and predates
    /// upload-only assignments, so absent must mean notebook.
    @Test func manifestWithoutSubmissionModeDecodesNotebook() throws {
        let json = #"{"schemaVersion":1}"#
        let decoded = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        #expect(decoded.submissionMode == .notebook)
    }

    @Test func submissionModeRoundTrips() throws {
        let manifest = TestProperties(submissionMode: .uploadOnly)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.submissionMode == .uploadOnly)
    }

    @Test func notebookByDefault() {
        #expect(TestProperties().submissionMode == .notebook)
    }

    /// The runner-facing manifest keeps the field (like gradingMode): losing
    /// it would make any runner-side re-read resolve the mode differently
    /// from the server.
    @Test func runnerSanitizedPreservesSubmissionMode() {
        let manifest = TestProperties(submissionMode: .uploadOnly)
        #expect(manifest.runnerSanitized().submissionMode == .uploadOnly)
    }

    /// The full truth table. Only the upload + browser cell differs from the
    /// stored mode — and that cell is the reason the property exists.
    @Test(arguments: [
        (GradingMode.worker, SubmissionMode.notebook, GradingMode.worker),
        (GradingMode.browser, SubmissionMode.notebook, GradingMode.browser),
        (GradingMode.worker, SubmissionMode.uploadOnly, GradingMode.worker),
        (GradingMode.browser, SubmissionMode.uploadOnly, GradingMode.worker),
    ])
    func effectiveGradingModePinsUploadToWorker(
        _ stored: GradingMode, _ submission: SubmissionMode, _ expected: GradingMode
    ) {
        let manifest = TestProperties(gradingMode: stored, submissionMode: submission)
        #expect(manifest.effectiveGradingMode == expected)
    }

    /// An unknown wire value must fail decoding loudly (enum decoder), not
    /// silently coerce — the same contract GradingMode has.
    @Test func unknownSubmissionModeFailsToDecode() {
        let json = #"{"schemaVersion":1,"submissionMode":"carrier-pigeon"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        }
    }
}
