// APIServer/Routes/SubmissionIntake.swift
//
// The one way a student submission enters the system (#2768). Seven doors
// create a student submission: the upload form, a GitHub commit, the two REST
// endpoints, and the three notebook endpoints (browser result, runner submit,
// browser failover). Each door does its own checks (enrollment, the deadline
// gate, the grading mode) and then hands its bytes here. This type owns every
// step after that: the file write, the row, the race-free attempt number and
// every effect of a saved row. The doors used to repeat those steps by hand,
// and the copies drifted: three of them never recorded diagnostics.
//
// It lives under Routes/ because it wakes the local runner, which is a route
// helper (`scripts/check-layering.sh`).

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Vapor

struct SubmissionIntake {
    let req: Request
    /// The new submission's ID. A door that writes its own file reads it first.
    var submissionID = freshShortID(prefix: "sub")

    /// Where the submission's file comes from.
    enum Artifact {
        /// Bytes to write at `path(fileExtension:)`.
        case bytes(Data, fileExtension: String)
        /// A file the door already wrote, at a path from `path(fileExtension:)`.
        /// A GitHub submission writes its zip while it converts the tarball.
        case stored(path: String)
    }

    /// The path in the submissions directory for this submission's file.
    func path(fileExtension: String) -> String {
        req.application.submissionsDirectory + "\(submissionID).\(fileExtension)"
    }

    /// Stores the file, saves the student row with the next attempt number, then runs
    /// every effect of a saved student submission:
    ///
    /// - When the row is `pending`, so a runner must grade it: the
    ///   "submission accepted" and "job enqueued" diagnostics, Pathfinder (first
    ///   to submit) when the row has an owner, and a wake of the local runner.
    /// - A `complete` row (a browser result) queues no job, so it records no
    ///   enqueue and wakes nothing. It is a real submission only once its result
    ///   is stored, so its door awards Pathfinder after that save
    ///   (`BrowserResultSideEffectOrderTests`).
    ///
    /// `owner` is nil only for the REST doors, which save no user on the row
    /// (see `SubmissionRoutes`). Their attempt number is then counted per setup.
    /// `prepare` sets any other column before the save, for example the GitHub
    /// source columns.
    @discardableResult
    func accept(
        setup: APITestSetup,
        owner: APIUser?,
        artifact: Artifact,
        filename: String?,
        status: SubmissionStatus,
        prepare: (APISubmission) -> Void = { _ in }
    ) async throws -> APISubmission {
        let storedPath: String
        switch artifact {
        case .bytes(let data, let fileExtension):
            storedPath = path(fileExtension: fileExtension)
            // Offloaded to the NIO thread pool: a synchronous write pins a
            // cooperative-pool thread for its duration, and a deadline burst is
            // exactly when these doors are hot.
            try await req.fileio.writeFile(.init(data: data), at: storedPath)
        case .stored(let path):
            storedPath = path
        }

        let submission = APISubmission(
            id: submissionID,
            testSetupID: try setup.requireID(),
            zipPath: storedPath,
            attemptNumber: 0,  // assigned by saveSubmissionWithNextAttemptNumber
            status: status.rawValue,
            filename: filename,
            userID: owner?.id,
            kind: APISubmission.Kind.student
        )
        prepare(submission)
        // Attempt number is scoped to this student for this test setup,
        // assigned race-free inside one transaction (concurrent submits used to
        // share a number, corrupting the prior-attempt delta and the
        // First-Try-Perfect badge).
        try await saveSubmissionWithNextAttemptNumber(submission, userID: owner?.id, on: req.db)

        // Everything below is a side effect of a row that is already stored,
        // so none of it may fail the submission (#1708).
        guard status == .pending else { return submission }
        await req.application.diagnostics.recordSubmissionCreated(
            submission: submission, on: req.db, logger: req.logger)
        if let userID = owner?.id {
            // The shared helper carries the v0.4.127 role gate: an admin, TA or
            // instructor testing the assignment must not lock in the immutable
            // badge.
            await ResultIngestEffects(application: req.application, db: req.db, logger: req.logger)
                .awardFirstToSubmit(setup: setup, userID: userID, submissionID: submissionID)
        }
        // Production runners poll on their own. This only starts the
        // development runner when the admin turned autostart on.
        await ensureLocalRunnerForSubmissionIfNeeded(req: req)
        return submission
    }

    /// The student's notebook with the instructor's test cells merged in, so a
    /// runner that grades the stored file has the hidden (release and secret)
    /// cells. When the instructor notebook cannot be read, the student's
    /// notebook is merged with itself: no hidden cells are added, but its own
    /// test cells move to the end and the contribution-slot limit still applies.
    ///
    /// Both the read and the merge block, so they run on the NIO thread pool,
    /// not the cooperative pool (#1156).
    func mergedWithInstructorNotebook(_ student: Data, setup: APITestSetup) async throws -> Data {
        let instructor: Data
        do {
            // Cached (#1171): a deadline spike shares one notebook resolution
            // instead of one unzip per submission.
            instructor = try await req.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            req.logger.warning(
                "Could not load instructor notebook for \(setup.id ?? "?"): \(error) — hidden test cells will not be injected"
            )
            instructor = student
        }
        return try await runBlocking { mergeNotebook(student: student, instructor: instructor) }
    }
}
