// APIServer/Routes/ResultRoutes.swift
//
// Persists TestOutcomeCollection to the DB (results table), then marks the
// originating submission as complete.

import Core
import Fluent
import Foundation
import Vapor

struct ResultRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "worker")
        api.post("results", use: reportResults)
    }

    /// Result-ingest body limit (#1157): well above the worker's own
    /// serialized-collection budget so a healthy report never hits it, and
    /// generous enough that pre-budget runners with oversized collections
    /// land in the server-side truncation guard below instead of a rejected
    /// report leaving the submission permanently unresolved.
    static let resultIngestBodyLimitBytes = 32 * 1024 * 1024

    // POST /api/v1/worker/results
    @Sendable
    func reportResults(req: Request) async throws -> ReportResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report: WorkerExecutionReport
        do {
            let collectedBuffer = try await req.body.collect(
                upTo: Self.resultIngestBodyLimitBytes
            )
            var readableBuffer = collectedBuffer
            guard let data = readableBuffer.readData(length: readableBuffer.readableBytes) else {
                throw WorkerJobError.invalidBody(reason: "Empty request body")
            }
            report = try decodeWorkerReport(from: data, using: decoder)
        } catch let decodingError as DecodingError {
            throw WorkerJobError.unprocessableBody(reason: "Invalid worker result payload: \(decodingError)")
        } catch {
            // A rejected report means a submission that never resolves —
            // fail LOUDLY so ops sees why (#1157).
            req.logger.error(
                "result_report_rejected reason=\(String(describing: error)) content_length=\(req.headers.first(name: .contentLength) ?? "?")"
            )
            throw error
        }

        // Server-side half of the size budget: current runners truncate
        // before posting; this guards against older runners and keeps the
        // unbounded blob out of the results table either way.
        let (collection, didTruncate) = report.collection.truncatingOversizedOutput()
        if didTruncate {
            // Submission id in metadata only — message text reaches the admin
            // query_logs buffer unredacted (compliance audit F-1).
            req.logger.warning(
                "result_collection_truncated — runner sent an over-budget collection",
                metadata: ["submission_id": .string(collection.submissionID)]
            )
        }

        // Persist the result and advance the submission to "complete" in one
        // transaction: a failure between the two used to leave a result row
        // with the submission stuck `assigned` until the stuck-submission
        // reaper re-queued and regraded it (wasted work, duplicate results).
        let completedSubmission = try await req.db.transaction { tx -> APISubmission? in
            try await persistToDB(collection, on: req, db: tx)
            guard let submission = try await APISubmission.find(collection.submissionID, on: tx)
            else { return nil }
            submission.setStatus(.complete)
            try await submission.save(on: tx)
            return submission
        }

        if let submission = completedSubmission {
            // Record execution diagnostics (execution time + queue wait).
            await req.application.diagnostics.recordWorkerExecutionReport(
                collection: collection,
                diagnostics: report.diagnostics,
                on: req.db,
                logger: req.logger
            )

            let effects = ResultIngestEffects(application: req.application, db: req.db, logger: req.logger)

            // A validation run's verdict, so the instructor sees pass or fail
            // without polling.
            if submission.kind == APISubmission.Kind.validation {
                try await effects.recordValidationVerdict(collection)
            }

            // A tournament match reaches only the bracket, whatever its
            // build status: a match that could not run advances the
            // opponent rather than stalling the round.
            if submission.kind == APISubmission.Kind.tournamentMatch {
                try await recordTournamentMatch(submission: submission, collection: collection, on: req.db)
            }

            // The class corpus run's grade IS the class's coverage number
            // (docs/collaborative-class-assignments.md). It belongs to no
            // student, so `ResultIngestEffects.apply` below skips it.
            if submission.kind == APISubmission.Kind.classAggregate {
                try await recordClassCoverageRun(
                    submission: submission, collection: collection, on: req.db)
            }

            // Coverage, the leaderboard, the match and the class records, best
            // effort: the result is committed, so none of them may fail the
            // report (#1708).
            await effects.apply(submission: submission, collection: collection, matches: report.matches)

            // An opted-in GitHub submission's public-tier result, on its commit
            // (docs/github-submissions.md slice 6). Runs after the response, so
            // a slow GitHub never holds the report.
            await GitHubCommitStatusPoster.startPost(submission: submission, collection: collection, req: req)
        }

        return ReportResponse(received: true)
    }

    // MARK: - DB persistence

    private func persistToDB(
        _ collection: TestOutcomeCollection, on req: Request, db: Database
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(collection), encoding: .utf8) ?? "{}"

        let result = APIResult(
            id: freshShortID(prefix: "res"),
            submissionID: collection.submissionID
        )

        // Mark for BrightSpace and LTI sync. Shared with the browser-result
        // path so the two ingest routes can't drift apart on which grades
        // reach the LMS.
        try await ResultIngestEffects.flagForGradeSync(
            result, testSetupID: collection.testSetupID, application: req.application, on: db)

        // Row + blob side-table row persist together; the caller's
        // transaction (persist + submission status flip) encloses both.
        try await result.saveWithCollection(json: json, on: db)
    }
}

/// Decodes a runner's result body: the wrapped `WorkerExecutionReport`.
///
/// The report is decoded as a whole: an earlier version rebuilt it from
/// `collection` and `diagnostics` alone and silently dropped `matches`, so no
/// round-robin match row ever completed over HTTP.
///
/// A legacy bare `TestOutcomeCollection` is refused (a `DecodingError`, which
/// the route reports as 422). Every runner at or above
/// `RunnerVersionGate.deploymentMinimumRunnerVersion` sends the wrapped form,
/// and a runner below that floor never claims a job (#1249).
func decodeWorkerReport(
    from data: Data,
    using decoder: JSONDecoder
) throws -> WorkerExecutionReport {
    try decoder.decode(WorkerExecutionReport.self, from: data)
}

// MARK: - Response

struct ReportResponse: Content {
    let received: Bool
}
