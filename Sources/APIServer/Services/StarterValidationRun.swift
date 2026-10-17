// APIServer/Services/StarterValidationRun.swift
//
// The starter run (notebook views NB8): each validation also grades the
// assignment notebook, the starter a student opens, against the suite. A test
// that passes on the starter and is worth points earns them for no work, so
// the workbench flags it (docs/notebook-guide.md, "The starter run").
//
// The run is one `starterValidation` submission. It carries the solution
// run's submitter, so personalization resolves with the same seed. It belongs
// to no grade: every listing, aggregate and grade selection filters on
// `student`. `validationStatus` stays the solution run's verdict, and only
// that verdict gates opening. The starter run never blocks.

import Core
import Fluent
import Foundation
import Vapor

enum StarterValidationRun {

    /// Queues a starter run for `setupID`, and removes every earlier starter
    /// run that no runner holds yet. A run of saves thus leaves one run in
    /// the queue, not one for each save.
    ///
    /// Best-effort, like the variant runs: a failure logs and never blocks
    /// the save. A setup with no assignment notebook (an upload-only
    /// language, or a suite of hand-written scripts) queues nothing.
    static func enqueue(
        context: some ServiceContext, setupID: String, submitterUserID: UUID?, targetRunnerID: String?
    ) async {
        do {
            guard let setup = try await APITestSetup.find(setupID, on: context.db),
                let starter = try? await notebookData(for: setup)
            else { return }
            let removed = try await removeQueued(setupID: setupID, on: context.db)
            for path in removed { try? FileManager.default.removeItem(atPath: path) }

            let subID = freshShortID(prefix: "sub")
            let path = context.application.submissionsDirectory + "\(subID).ipynb"
            try starter.write(to: URL(fileURLWithPath: path))
            let submission = APISubmission(
                id: subID, testSetupID: setupID, zipPath: path, attemptNumber: 1,
                filename: "assignment.ipynb", userID: submitterUserID, kind: APISubmission.Kind.starterValidation)
            submission.targetRunnerID = targetRunnerID
            let job = await materializeValidationGrading(
                submission: submission, setupID: setupID, templateNotebookData: starter,
                testSetupsDirectory: context.application.testSetupsDirectory, app: context.application,
                on: context.db)
            try await job.saveClaimable(on: context.db)
        } catch {
            context.logger.warning("starter run: enqueue for \(setupID) failed: \(error)")
        }
    }

    /// The newest starter run of `setupID` that has a result, with that
    /// result, or nil.
    static func latest(setupID: String, on db: any Database) async throws -> TestOutcomeCollection? {
        let runs = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.starterValidation)
            .filter(\.$status == SubmissionStatus.complete.rawValue)
            .sort(\.$submittedAt, .descending)
            .limit(1)
            .all()
        guard let id = runs.first?.id,
            let result = try await APIResult.query(on: db).filter(\.$submissionID == id)
                .sort(\.$receivedAt, .descending).first(),
            let json = try await result.loadCollectionJSON(on: db)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TestOutcomeCollection.self, from: Data(json.utf8))
    }

    /// Why a starter run did not run, or nil when it ran. A starter that does
    /// not build, or whose every test errors (a syntax error in the starter),
    /// did not run: its outcomes say nothing about the tests.
    static func failure(of run: TestOutcomeCollection) -> String? {
        if run.buildStatus == .failed {
            return firstLine(run.compilerOutput) ?? "the build failed"
        }
        guard !run.outcomes.isEmpty else { return "no test ran" }
        guard run.outcomes.allSatisfy({ $0.status == .error }) else { return nil }
        return firstLine(run.outcomes.first?.shortResult) ?? "every test reported an error"
    }

    private static func firstLine(_ text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        return line.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// Removes the setup's queued starter runs. A run that a runner holds
    /// finishes, and the newest result wins. Returns the files to delete.
    private static func removeQueued(setupID: String, on db: any Database) async throws -> [String] {
        let queued = try await APISubmission.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.starterValidation)
            .filter(\.$status == SubmissionStatus.pending.rawValue)
            .all()
        guard !queued.isEmpty else { return [] }
        try await APISubmission.query(on: db).filter(\.$id ~~ queued.compactMap(\.id)).delete()
        return queued.flatMap { [$0.zipPath, $0.zipPath + ".grading"] }
    }
}
