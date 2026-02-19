// Worker/BuildServerBackend.swift
//
// Protocol-based backend for dependency injection and testability.
// Spec §7: "BuildServer (the core actor) depends only on BuildServerBackend
//           — never on DaemonBackend directly."
//
// Concrete implementations:
//   DaemonBackend   — production HTTP implementation
//   (TestHarnessBackend — local-file implementation, added in WorkerTests)

import Foundation
import Core

protocol BuildServerBackend: Actor {
    /// Request the next pending submission matching this worker's supported
    /// languages.  Returns `nil` (HTTP 204) when no work is available.
    func fetchSubmission() async throws -> Job?

    /// Download the submission zip to `destination`.
    func downloadSubmission(_ job: Job, to destination: URL) async throws

    /// Download the test-setup zip to `destination`.
    func downloadTestSetup(_ job: Job, to destination: URL) async throws

    /// POST the completed `TestOutcomeCollection` back to the API server.
    func reportResults(_ results: TestOutcomeCollection, for job: Job) async throws

    /// Best-effort notification that a job died unexpectedly (no throw).
    func reportDeath(submissionID: String, testSetupID: String) async
}
