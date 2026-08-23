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

                // A per-variant run (multi-variant validation) is never the
                // assignment's linked primary, so the two lookups are
                // disjoint: this one records the verdict on the variant row
                // the instructor surfaces read.
                if let variant = try await ValidationVariant.query(on: req.db)
                    .filter(\.$submissionID == collection.submissionID)
                    .first()
                {
                    variant.status = status
                    try await variant.save(on: req.db)
                    req.logger.info(
                        "Validation variant \(variant.variantIndex) \(status) for setup \(variant.testSetupID)"
                    )
                }
            }

            try await applyClassWideEffects(
                submission: submission, collection: collection, on: req)
        }

        return ReportResponse(received: true)
    }

    // MARK: - Class-wide effects

    /// The class-level side effects of one student result: the union of covered
    /// items, and the class badges a 100% earns.
    ///
    /// Extracted from `report` because it is the part that GROWS — every
    /// class-level signal added to the platform lands here, and inlining them
    /// pushed the route past the body-length limit. Keeping it separate also
    /// keeps the two gates visible: coverage is per item and ungated by grade,
    /// badges are per student and gated at 100%.
    private func applyClassWideEffects(
        submission: APISubmission, collection: TestOutcomeCollection, on req: Request
    ) async throws {
        guard submission.kind == APISubmission.Kind.student,
            collection.buildStatus == .passed,
            let userID = submission.userID,
            let subID = submission.id
        else { return }

        // Per item, and deliberately not inside the 100% gate below: a student
        // who covers one item and nothing else has still contributed that item.
        //
        // Only contribution assignments accumulate a union, so the slot count
        // comes from the instructor's starter notebook. Read through
        // `notebookBytesCache` (#1171) rather than unzipping per result: a
        // deadline spike shares one resolution. A setup with no notebook
        // resolves to nil, which is 0 slots, which is "not a contribution
        // assignment" — the right answer for every ordinary assignment.
        let slotCount = await declaredContributionSlotCount(
            testSetupID: submission.testSetupID, app: req.application, on: req.db)
        try await recordClassItemCoverage(
            testSetupID: submission.testSetupID,
            userID: userID,
            submissionID: subID,
            outcomes: collection.outcomes,
            declaredSlotCount: slotCount,
            on: req.db
        )

        guard gradePercent(from: collection) == 100 else { return }
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

    // MARK: - DB persistence

    private func persistToDB(
        _ collection: TestOutcomeCollection, on req: Request, db: Database
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try String(data: encoder.encode(collection), encoding: .utf8) ?? "{}"

        let result = APIResult(
            id: "res_\(UUID().uuidString.lowercased().prefix(8))",
            submissionID: collection.submissionID
        )

        // Mark for BrightSpace sync if the assignment is configured for it.
        // Shared with the browser-result path so the two ingest routes can't
        // drift apart on which grades reach LEARN.
        try await flagResultForBrightSpaceSync(
            result, testSetupID: collection.testSetupID, application: req.application, on: db)

        // Row + blob side-table row persist together; the caller's
        // transaction (persist + submission status flip) encloses both.
        try await result.saveWithCollection(json: json, on: db)
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
