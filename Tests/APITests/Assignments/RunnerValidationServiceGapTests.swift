// Tests/APITests/Assignments/RunnerValidationServiceGapTests.swift
//
// Paths of `RunnerValidationService.swift` that other suites do not reach:
// the re-test flip that leaves an in-flight row alone, the grading sidecar a
// clone of a materialized validation carries, and the local-runner
// autostart branches of the two runner-availability probes. The autostart
// tests clear the worker secret, so `LocalRunnerManager.ensureRunning` logs
// that the secret is empty and starts no process.

import Fluent
import Foundation
import Logging
import Testing
import Vapor

@testable import APIServer
@testable import Core

// MARK: - Context with a captured log

/// A `ServiceContext` whose logger is the capture's.
private struct ValidationGapContext: ServiceContext {
    let application: Application
    let logger: Logger
    var db: any Database { application.db }
    var actingUserID: UUID? { nil }
}

// MARK: - Suite

@Suite(.serialized, .timeLimit(.minutes(2)))
struct RunnerValidationServiceGapTests {

    private static let emptySecretWarning = "worker secret is empty"

    private static let substitutionManifest = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,\
        "globalVariables":[{"name":"answer","value":"ck_gap_marker"}]}
        """

    private static let plainManifest = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    /// Autostart on or off, the worker secret cleared, and a context whose
    /// warnings are captured.
    private static func context(
        _ app: Application, autostart: Bool
    ) async -> (ValidationGapContext, CapturedLog) {
        await app.localRunnerAutoStartStore.setEnabled(autostart)
        await app.workerSecretStore.setRuntimeOverride(nil)
        let capture = CapturedLog(minimumLevel: .warning)
        return (ValidationGapContext(application: app, logger: capture.logger), capture)
    }

    // MARK: flipSubmissionToPending

    /// A row already pending or assigned is left alone unless forced; a
    /// forced flip clears the claim and stamps who re-tested it.
    @Test func anInFlightRowFlipsOnlyWhenForced() async throws {
        try await withTestApp { app in
            let setupID = "valgap_flip_setup"
            let courseID = try await app.testCourseID()
            _ = try await makeTestSetup(
                on: app, id: setupID, courseID: courseID, manifest: Self.plainManifest,
                withNotebook: false, withZip: false)
            let staff = try await makeTestUser(on: app, username: "valgap_staff", role: "instructor")
            let staffID = try staff.requireID()

            let pending = APISubmission(
                id: "valgap_pending", testSetupID: setupID, zipPath: "/tmp/none.zip", attemptNumber: 1,
                status: SubmissionStatus.pending.rawValue, kind: APISubmission.Kind.student)
            try await pending.save(on: app.db)
            let assigned = APISubmission(
                id: "valgap_assigned", testSetupID: setupID, zipPath: "/tmp/none.zip", attemptNumber: 1,
                status: SubmissionStatus.assigned.rawValue, kind: APISubmission.Kind.student)
            assigned.workerID = "worker-1"
            assigned.assignedAt = Date()
            try await assigned.save(on: app.db)

            #expect(try await flipSubmissionToPending(pending, triggeredBy: staffID, on: app.db) == false)
            #expect(try await flipSubmissionToPending(assigned, triggeredBy: staffID, on: app.db) == false)
            let untouched = try #require(try await APISubmission.find("valgap_assigned", on: app.db))
            #expect(untouched.statusValue == .assigned)
            #expect(untouched.workerID == "worker-1")
            #expect(untouched.retestedAt == nil)
            #expect(untouched.retestedByUserID == nil)

            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(
                try await flipSubmissionToPending(assigned, triggeredBy: staffID, on: app.db, force: true, now: now))
            let forced = try #require(try await APISubmission.find("valgap_assigned", on: app.db))
            #expect(forced.statusValue == .pending)
            #expect(forced.workerID == nil)
            #expect(forced.assignedAt == nil)
            #expect(forced.retestedByUserID == staffID)
            let stamped = try #require(forced.retestedAt)
            #expect(abs(stamped.timeIntervalSince(now)) < 1)
        }
    }

    // MARK: MaterializedValidationSubmission.cloned

    /// A clone of a materialized validation carries the substituted sidecar
    /// and the same cache, so the personalization runs once for many jobs.
    @Test func aCloneCopiesTheGradingSidecarAndSharesTheCache() async throws {
        try await withTestApp { app in
            let setupID = "valgap_clone_setup"
            let courseID = try await app.testCourseID()
            _ = try await makeTestSetup(
                on: app, id: setupID, courseID: courseID, manifest: Self.substitutionManifest,
                withNotebook: false, withZip: false)
            let template = Data(
                """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","metadata":{},"execution_count":null,"outputs":[],"source":"x = {{answer}}"}]}
                """.utf8)
            let originalPath = app.submissionsDirectory + "valgap_orig.ipynb"
            try template.write(to: URL(fileURLWithPath: originalPath))
            let original = APISubmission(
                id: "valgap_orig", testSetupID: setupID, zipPath: originalPath, attemptNumber: 1,
                status: SubmissionStatus.pending.rawValue, filename: "solution.ipynb",
                kind: APISubmission.Kind.validation)

            let materialized = await materializeValidationGrading(
                submission: original, setupID: setupID, templateNotebookData: template,
                testSetupsDirectory: app.testSetupsDirectory, app: app, on: app.db)
            let sidecar = originalPath + ".grading"
            let body = try String(contentsOf: URL(fileURLWithPath: sidecar), encoding: .utf8)
            #expect(body.contains("ck_gap_marker"))
            #expect(!body.contains("{{answer}}"))
            let cache = try #require(original.materializationJSON)

            let clonePath = app.submissionsDirectory + "valgap_clone.ipynb"
            try template.write(to: URL(fileURLWithPath: clonePath))
            let clone = APISubmission(
                id: "valgap_clone", testSetupID: setupID, zipPath: clonePath, attemptNumber: 1,
                status: SubmissionStatus.pending.rawValue, filename: "solution.ipynb",
                kind: APISubmission.Kind.validation)
            let cloned = try materialized.cloned(as: clone)

            #expect(clone.materializationJSON == cache)
            let cloneBody = try String(contentsOf: URL(fileURLWithPath: clonePath + ".grading"), encoding: .utf8)
            #expect(cloneBody == body)

            // The clone's token is the one save that makes its row claimable.
            try await cloned.saveClaimable(on: app.db)
            let saved = try #require(try await APISubmission.find("valgap_clone", on: app.db))
            #expect(saved.materializationJSON == cache)
        }
    }

    /// With nothing to personalize there is no sidecar, and the clone gets
    /// none either.
    @Test func aCloneOfAnUnpersonalizedRunHasNoSidecar() async throws {
        try await withTestApp { app in
            let setupID = "valgap_plain_setup"
            let courseID = try await app.testCourseID()
            _ = try await makeTestSetup(
                on: app, id: setupID, courseID: courseID, manifest: Self.plainManifest,
                withNotebook: false, withZip: false)
            let template = Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)
            let originalPath = app.submissionsDirectory + "valgap_plain.ipynb"
            try template.write(to: URL(fileURLWithPath: originalPath))
            let original = APISubmission(
                id: "valgap_plain", testSetupID: setupID, zipPath: originalPath, attemptNumber: 1,
                status: SubmissionStatus.pending.rawValue, filename: "solution.ipynb",
                kind: APISubmission.Kind.validation)
            let materialized = await materializeValidationGrading(
                submission: original, setupID: setupID, templateNotebookData: template,
                testSetupsDirectory: app.testSetupsDirectory, app: app, on: app.db)

            let clonePath = app.submissionsDirectory + "valgap_plain_clone.ipynb"
            let clone = APISubmission(
                id: "valgap_plain_clone", testSetupID: setupID, zipPath: clonePath, attemptNumber: 1,
                status: SubmissionStatus.pending.rawValue, filename: "solution.ipynb",
                kind: APISubmission.Kind.validation)
            _ = try materialized.cloned(as: clone)

            #expect(original.materializationJSON == nil)
            #expect(clone.materializationJSON == nil)
            #expect(!FileManager.default.fileExists(atPath: clonePath + ".grading"))
        }
    }

    // MARK: ensureValidationRunnerAvailability

    /// Autostart off: nothing is started and nothing is logged.
    @Test func availabilityDoesNothingWithAutostartOff() async throws {
        try await withTestApp { app in
            let (context, capture) = await Self.context(app, autostart: false)
            await ensureValidationRunnerAvailability(context: context)
            #expect(capture.messages(containing: Self.emptySecretWarning).isEmpty)
        }
    }

    /// Autostart on, but a runner checked in moments ago: no local runner
    /// is started.
    @Test func availabilityDoesNothingWhenARunnerIsRecent() async throws {
        try await withTestApp { app in
            let (context, capture) = await Self.context(app, autostart: true)
            await app.workerActivityStore.markActive(workerID: "valgap-recent", hostname: "host-a")
            await ensureValidationRunnerAvailability(context: context)
            #expect(capture.messages(containing: Self.emptySecretWarning).isEmpty)
        }
    }

    /// Autostart on and no runner seen: the server tries to start its local
    /// runner. With no worker secret it refuses and says why.
    @Test func availabilityTriesTheLocalRunnerWhenNoneIsRecent() async throws {
        try await withTestApp { app in
            let (context, capture) = await Self.context(app, autostart: true)
            await ensureValidationRunnerAvailability(context: context)
            #expect(capture.messages(containing: Self.emptySecretWarning).count == 1)
        }
    }

    // MARK: ensureCompatibleValidationRunnerAvailability

    /// No compatible runner and autostart off: the probe answers false at
    /// once and starts nothing.
    @Test func compatibleProbeAnswersFalseWithAutostartOff() async throws {
        try await withTestApp { app in
            let (context, capture) = await Self.context(app, autostart: false)
            let available = try await ensureCompatibleValidationRunnerAvailability(
                context: context, requirements: nil)
            #expect(available == false)
            #expect(capture.messages(containing: Self.emptySecretWarning).isEmpty)
        }
    }

    /// No compatible runner and autostart on: the probe tries the local
    /// runner before each re-check but the last, and answers false when no
    /// runner comes up.
    @Test func compatibleProbeRetriesTheLocalRunnerThenAnswersFalse() async throws {
        try await withTestApp { app in
            let (context, capture) = await Self.context(app, autostart: true)
            let available = try await ensureCompatibleValidationRunnerAvailability(
                context: context, requirements: nil, attempts: 2)
            #expect(available == false)
            #expect(capture.messages(containing: Self.emptySecretWarning).count == 2)
            #expect(try await RunnerProfile.query(on: app.db).count() == 0)
        }
    }
}
