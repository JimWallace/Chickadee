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

    // POST /api/v1/worker/results
    @Sendable
    func reportResults(req: Request) async throws -> ReportResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report: WorkerExecutionReport
        do {
            let collectedBuffer = try await req.body.collect(
                upTo: req.application.routes.defaultMaxBodySize.value
            )
            var readableBuffer = collectedBuffer
            guard let data = readableBuffer.readData(length: readableBuffer.readableBytes) else {
                throw WorkerJobError.invalidBody(reason: "Empty request body")
            }
            report = try decodeWorkerReport(from: data, using: decoder)
        } catch let decodingError as DecodingError {
            throw WorkerJobError.unprocessableBody(reason: "Invalid worker result payload: \(decodingError)")
        }
        let collection = report.collection

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

            // If this is a validation submission, update the assignment's validationStatus
            // so the instructor sees pass/fail without needing to poll.
            if submission.kind == APISubmission.Kind.validation {
                let passed =
                    collection.buildStatus == .passed
                    && collection.totalTests > 0
                    && collection.failCount == 0
                    && collection.errorCount == 0
                    && collection.timeoutCount == 0
                let status = passed ? "passed" : "failed"

                if let assignment = try await APIAssignment.query(on: req.db)
                    .filter(\.$validationSubmissionID == collection.submissionID)
                    .first()
                {
                    assignment.validationStatus = status
                    try await assignment.save(on: req.db)
                    req.logger.info(
                        "Validation \(status) for assignment '\(assignment.title)' (submission \(collection.submissionID))"
                    )
                }
            }

            // Award class-wide badges when a student submission earns 100%.
            if submission.kind == APISubmission.Kind.student,
                collection.buildStatus == .passed,
                let userID = submission.userID,
                let subID = submission.id
            {
                let grade = gradePercent(from: collection) ?? 0
                if grade == 100 {
                    let disabled =
                        (try? await APITestSetup.find(submission.testSetupID, on: req.db))
                        .map { BuiltInAchievements.disabled(in: $0) } ?? []
                    try await awardClassBadgesFor100Percent(
                        testSetupID: submission.testSetupID,
                        userID: userID,
                        submissionID: subID,
                        executionTimeMs: collection.executionTimeMs,
                        attemptNumber: submission.attemptNumber ?? 1,
                        disabled: disabled,
                        on: req.db
                    )
                }
            }
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
            id: "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID: collection.submissionID,
            collectionJSON: json
        )

        // Mark for BrightSpace sync if the assignment is configured for it. Gate
        // on app-level config (not a live global client) so per-instructor-only
        // deployments still flag results for the per-course sync to pick up.
        if req.application.brightSpaceAppCredentials != nil {
            if let assignment = try await APIAssignment.query(on: db)
                .filter(\.$testSetupID == collection.testSetupID)
                .first(),
                let gradeObjectID = assignment.brightspaceGradeObjectID,
                !gradeObjectID.isEmpty,
                let course = try await APICourse.find(assignment.courseID, on: db),
                let orgUnitID = course.brightspaceOrgUnitID,
                !orgUnitID.isEmpty
            {
                let now = Date()
                result.brightspaceSyncPending = true
                result.brightspacePendingSince = now
            }
        }

        try await result.save(on: db)
    }
}

private func decodeWorkerReport(
    from data: Data,
    using decoder: JSONDecoder
) throws -> WorkerExecutionReport {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let collectionObject = json["collection"]
    {
        let collectionData = try JSONSerialization.data(withJSONObject: collectionObject)
        let collection = try decoder.decode(TestOutcomeCollection.self, from: collectionData)

        let diagnostics: WorkerExecutionDiagnostics?
        if let diagnosticsObject = json["diagnostics"], !(diagnosticsObject is NSNull) {
            let diagnosticsData = try JSONSerialization.data(withJSONObject: diagnosticsObject)
            diagnostics = try decoder.decode(WorkerExecutionDiagnostics.self, from: diagnosticsData)
        } else {
            diagnostics = nil
        }

        return WorkerExecutionReport(collection: collection, diagnostics: diagnostics)
    }

    if let report = try? decoder.decode(WorkerExecutionReport.self, from: data) {
        return report
    }

    let collection = try decoder.decode(TestOutcomeCollection.self, from: data)
    return WorkerExecutionReport(collection: collection, diagnostics: nil)
}

// MARK: - Response

struct ReportResponse: Content {
    let received: Bool
}
