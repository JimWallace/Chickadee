// APIServer/Routes/SubmissionQueryRoutes.swift
//
// Phase 3: student-facing read endpoints.
//
//   GET /api/v1/submissions                   — list submissions
//   GET /api/v1/submissions/:id               — submission status
//   GET /api/v1/submissions/:id/results       — grading results (with optional tier filter)

import Vapor
import Fluent
import Core
import Foundation

struct SubmissionQueryRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let subs = routes.grouped("api", "v1", "submissions")
        subs.get(use: listSubmissions)
        subs.get(":submissionID", use: getSubmission)
        subs.get(":submissionID", "results", use: getResults)
    }

    // MARK: - GET /api/v1/submissions

    @Sendable
    func listSubmissions(req: Request) async throws -> SubmissionListResponse {
        let caller = try req.auth.require(APIUser.self)
        var query = APISubmission.query(on: req.db)
            .sort(\.$submittedAt, .descending)

        if let testSetupID = req.query[String.self, at: "testSetupID"] {
            query = query.filter(\.$testSetupID == testSetupID)
        }
        if !caller.isInstructor {
            query = query.filter(\.$userID == caller.id)
        }

        let submissions = try await query.all()
        return SubmissionListResponse(
            submissions: submissions.map(SubmissionSummary.init)
        )
    }

    // MARK: - GET /api/v1/submissions/:id

    @Sendable
    func getSubmission(req: Request) async throws -> SubmissionStatusResponse {
        let caller = try req.auth.require(APIUser.self)
        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        guard canViewSubmission(caller: caller, submission: submission) else {
            throw Abort(.forbidden)
        }
        return SubmissionStatusResponse(submission: submission)
    }

    // MARK: - GET /api/v1/submissions/:id/results

    @Sendable
    func getResults(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        guard canViewSubmission(caller: caller, submission: submission) else {
            throw Abort(.forbidden)
        }

        guard let result = try await APIResult.query(on: req.db)
            .filter(\.$submissionID == subID)
            .sort(\.$receivedAt, .descending)
            .first()
        else {
            throw Abort(.notFound, reason: "No results available yet for submission \(subID)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let data = result.collectionJSON.data(using: .utf8),
            var collection = try? decoder.decode(TestOutcomeCollection.self, from: data)
        else {
            throw Abort(.internalServerError, reason: "Stored result is corrupt")
        }

        // Optional tier filter: ?tiers=public,student
        if let tiersParam = req.query[String.self, at: "tiers"] {
            let requested = Set(tiersParam.split(separator: ",").map(String.init))
            collection = collection.filtering(tiers: requested)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let responseData = try encoder.encode(collection)

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: responseData)
        )
    }
}

private func canViewSubmission(caller: APIUser, submission: APISubmission) -> Bool {
    if caller.isInstructor { return true }
    return submission.userID == caller.id
}

// MARK: - Tier filtering

private extension TestOutcomeCollection {
    /// Returns a copy with outcomes filtered to the given tier raw values,
    /// with all aggregate counts recomputed.
    func filtering(tiers: Set<String>) -> TestOutcomeCollection {
        // Map raw string to TestTier and filter.
        let filtered = outcomes.filter { outcome in
            tiers.contains(outcome.tier.rawValue)
        }
        return TestOutcomeCollection(
            submissionID:    submissionID,
            testSetupID:     testSetupID,
            attemptNumber:   attemptNumber,
            buildStatus:     buildStatus,
            compilerOutput:  compilerOutput,
            outcomes:        filtered,
            totalTests:      filtered.count,
            passCount:       filtered.filter { $0.status == .pass    }.count,
            failCount:       filtered.filter { $0.status == .fail    }.count,
            errorCount:      filtered.filter { $0.status == .error   }.count,
            timeoutCount:    filtered.filter { $0.status == .timeout }.count,
            executionTimeMs: executionTimeMs,
            runnerVersion:   runnerVersion,
            timestamp:       timestamp
        )
    }
}

// MARK: - Response types

struct SubmissionListResponse: Content {
    let submissions: [SubmissionSummary]
}

struct SubmissionSummary: Content {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let submittedAt: Date?

    init(_ submission: APISubmission) {
        self.submissionID  = submission.id ?? ""
        self.testSetupID   = submission.testSetupID
        self.status        = submission.status
        self.attemptNumber = submission.attemptNumber ?? 1
        self.submittedAt   = submission.submittedAt
    }
}

struct SubmissionStatusResponse: Content {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let submittedAt: Date?
    let assignedAt: Date?

    init(submission: APISubmission) {
        self.submissionID  = submission.id ?? ""
        self.testSetupID   = submission.testSetupID
        self.status        = submission.status
        self.attemptNumber = submission.attemptNumber ?? 1
        self.submittedAt   = submission.submittedAt
        self.assignedAt    = submission.assignedAt
    }
}
