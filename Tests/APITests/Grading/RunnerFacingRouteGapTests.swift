// Tests/APITests/Grading/RunnerFacingRouteGapTests.swift
//
// The runner-facing API paths that the other worker suites leave out:
//
// - POST /api/v1/worker/request: a workerID that another host holds is
//   refused with 409; the language gate refuses a runner that lacks the
//   declared language, end to end; the job's download URLs come from the
//   configured base URL, the forwarded headers, the Host header or the bind
//   address, in that order.
// - POST /api/v1/worker/heartbeat and /results: an unsigned request is
//   refused and records nothing.
// - POST /api/v1/worker/results: the class corpus kind completes its coverage
//   run; the best-effort kinds land their result with no backing row.
// - WorkerJobClaim: a store without SQL takes the Fluent probe and refuses
//   the claim.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) struct RunnerFacingRouteGapTests {

    // MARK: - Worker ID conflicts

    /// A second host that polls with a workerID an active runner holds gets
    /// 409, claims nothing, and does not take over the activity entry. The
    /// first host's own re-poll is a restart, not a conflict, and claims.
    @Test func aWorkerIDHeldByAnotherHostIsRefusedAndClaimsNothing() async throws {
        try await rfgWithApp { app in
            #expect(try await rfgPoll(app, workerID: "shared-id", hostname: "host-a.local").status == .noContent)

            let setup = try await rfgSetup(app, id: "rfg_conflict")
            let submission = try await rfgSubmission(app, id: "rfg_conflict_sub", setupID: try setup.requireID())

            let refused = try await rfgPoll(app, workerID: "shared-id", hostname: "host-b.local")
            #expect(refused.status == .conflict)
            let message = try refused.content.decode(RFGErrorBody.self).error
            #expect(message.contains("\"shared-id\""))
            #expect(message.contains("--worker-id"))

            let untouched = try #require(try await APISubmission.find(try submission.requireID(), on: app.db))
            #expect(untouched.status == SubmissionStatus.pending.rawValue)
            #expect(untouched.workerID == nil)
            let entry = try #require(await app.workerActivityStore.snapshot(for: "shared-id"))
            #expect(entry.hostname == "host-a.local")

            let restarted = try await rfgPoll(app, workerID: "shared-id", hostname: "host-a.local")
            #expect(restarted.status == .ok)
            let claimed = try #require(try await APISubmission.find(try submission.requireID(), on: app.db))
            #expect(claimed.status == SubmissionStatus.assigned.rawValue)
            #expect(claimed.workerID == "shared-id")
        }
    }

    // MARK: - Language gate, end to end

    /// A runner whose profile lacks the declared language leaves the job
    /// pending. A runner that advertises it claims the job.
    @Test func theLanguageGateLeavesTheJobForARunnerThatHasTheLanguage() async throws {
        try await rfgWithApp { app in
            let manifest = """
                {"schemaVersion":1,"gradingMode":"worker","language":"octave","languageDeclared":true,\
                "requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
                """
            let setup = try await rfgSetup(app, id: "rfg_octave", manifest: manifest)
            let submission = try await rfgSubmission(app, id: "rfg_octave_sub", setupID: try setup.requireID())

            let refused = try await rfgPoll(
                app, workerID: "python-only", hostname: "python-only.local",
                profile: rfgProfile(languages: ["python"]))
            #expect(refused.status == .noContent)
            let pending = try #require(try await APISubmission.find(try submission.requireID(), on: app.db))
            #expect(pending.status == SubmissionStatus.pending.rawValue)
            #expect(pending.workerID == nil)

            let admitted = try await rfgPoll(
                app, workerID: "has-octave", hostname: "has-octave.local",
                profile: rfgProfile(languages: ["python", "octave"]))
            #expect(admitted.status == .ok)
            let job = try admitted.content.decode(Job.self)
            #expect(job.submissionID == "rfg_octave_sub")
            #expect(job.language == .octave)
            let claimed = try #require(try await APISubmission.find(try submission.requireID(), on: app.db))
            #expect(claimed.status == SubmissionStatus.assigned.rawValue)
            #expect(claimed.workerID == "has-octave")
        }
    }

    // MARK: - Download URL base

    /// The configured worker base URL wins over every request header.
    @Test func theConfiguredWorkerBaseURLWinsOverTheRequestHeaders() async throws {
        let defaults = AppConfig.testDefaults()
        let config = AppConfig(
            auth: defaults.auth, oidc: defaults.oidc, security: defaults.security, scanMode: defaults.scanMode,
            database: defaults.database, lockout: defaults.lockout,
            workers: WorkerConfig(sharedSecret: nil, publicBaseURL: "https://grading.example.edu"),
            brightspace: defaults.brightspace, brightspaceApp: defaults.brightspaceApp,
            diagnostics: defaults.diagnostics, alerts: defaults.alerts, outboundProxy: defaults.outboundProxy,
            mcp: defaults.mcp, uwDates: defaults.uwDates)
        try await rfgWithApp(appConfig: config) { app in
            let setup = try await rfgSetup(app, id: "rfg_base")
            _ = try await rfgSubmission(app, id: "rfg_base_sub", setupID: try setup.requireID())

            let response = try await rfgPoll(
                app, workerID: "base-runner", hostname: "base-runner.local",
                extraHeaders: [("X-Forwarded-Host", "proxy.example.edu"), ("Host", "ignored.example")])
            #expect(response.status == .ok)
            let job = try response.content.decode(Job.self)
            #expect(
                job.submissionURL.absoluteString
                    == "https://grading.example.edu/api/v1/worker/submissions/rfg_base_sub/download")
            #expect(job.testSetupURL.absoluteString.hasPrefix("https://grading.example.edu/api/v1/worker/testsetups/"))
        }
    }

    /// With no configured base, the first comma-separated value of the
    /// forwarded headers wins, then the Host header. A forwarded host whose
    /// first value is blank counts as absent.
    @Test(arguments: [
        RFGHeaderCase(
            headers: [("X-Forwarded-Host", "proxy.example.edu, edge.internal"), ("X-Forwarded-Proto", "https, http")],
            expectedBase: "https://proxy.example.edu"),
        RFGHeaderCase(
            headers: [("X-Forwarded-Host", " , edge.internal"), ("Host", "runner-facing.example:8080")],
            expectedBase: "http://runner-facing.example:8080"),
        RFGHeaderCase(
            headers: [("Host", "runner-facing.example:8080"), ("X-Forwarded-Proto", "https")],
            expectedBase: "https://runner-facing.example:8080"),
    ])
    func theForwardedHeadersThenTheHostHeaderNameTheBase(_ testCase: RFGHeaderCase) async throws {
        try await rfgWithApp { app in
            let setup = try await rfgSetup(app, id: "rfg_fwd")
            _ = try await rfgSubmission(app, id: "rfg_fwd_sub", setupID: try setup.requireID())

            let response = try await rfgPoll(
                app, workerID: "fwd-runner", hostname: "fwd-runner.local", extraHeaders: testCase.headers)
            #expect(response.status == .ok)
            let job = try response.content.decode(Job.self)
            #expect(
                job.submissionURL.absoluteString
                    == "\(testCase.expectedBase)/api/v1/worker/submissions/rfg_fwd_sub/download")
        }
    }

    /// With no header at all, the base is the bind address, and a wildcard
    /// or blank bind address reads as localhost.
    @Test(arguments: ["0.0.0.0", "::", "  "])
    func aWildcardBindAddressReadsAsLocalhost(_ bindHost: String) async throws {
        try await rfgWithApp { app in
            app.http.server.configuration.hostname = bindHost
            app.http.server.configuration.port = 8_099
            let setup = try await rfgSetup(app, id: "rfg_bind")
            _ = try await rfgSubmission(app, id: "rfg_bind_sub", setupID: try setup.requireID())

            let response = try await rfgPoll(app, workerID: "bind-runner", hostname: "bind-runner.local")
            #expect(response.status == .ok)
            let job = try response.content.decode(Job.self)
            #expect(
                job.submissionURL.absoluteString
                    == "http://localhost:8099/api/v1/worker/submissions/rfg_bind_sub/download")
        }
    }

    // MARK: - Unsigned requests

    /// An unsigned heartbeat is refused and the runner is not recorded.
    @Test func anUnsignedHeartbeatIsRefusedAndRecordsNothing() async throws {
        try await rfgWithApp { app in
            let body = try rfgActivityBody(workerID: "unsigned-runner", hostname: "unsigned.local")
            let response = try await app.asyncSendRequest(.POST, "/api/v1/worker/heartbeat") { req in
                req.headers.contentType = .json
                req.body = body
            }
            #expect(response.status == .unauthorized)
            #expect(await app.workerActivityStore.snapshot(for: "unsigned-runner") == nil)
        }
    }

    /// A report signed with the wrong secret is refused before the claim
    /// check: no result row, and the row stays with its runner.
    @Test func aReportSignedWithTheWrongSecretStoresNothing() async throws {
        try await rfgWithApp { app in
            let setup = try await rfgSetup(app, id: "rfg_wrongsig")
            let submission = try await rfgSubmission(app, id: "rfg_wrongsig_sub", setupID: try setup.requireID())
            try await markClaimedForResultReport("rfg_wrongsig_sub", on: app.db)

            let body = try rfgReportBody(rfgCollection(submissionID: "rfg_wrongsig_sub", setupID: "rfg_wrongsig"))
            let path = "/api/v1/worker/results"
            let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: "not-the-secret")
            let response = try await app.asyncSendRequest(.POST, path) { req in
                req.headers = headers
                req.body = body
            }
            #expect(response.status == .unauthorized)
            #expect(try await APIResult.query(on: app.db).filter(\.$submissionID == "rfg_wrongsig_sub").count() == 0)
            let row = try #require(try await APISubmission.find(try submission.requireID(), on: app.db))
            #expect(row.status == SubmissionStatus.assigned.rawValue)
            #expect(row.workerID == "test-runner")
        }
    }

    // MARK: - Result kinds

    /// A class corpus run's report completes its coverage run with the
    /// earned fraction of the points.
    @Test func aClassCorpusReportCompletesItsCoverageRun() async throws {
        try await rfgWithApp { app in
            let setup = try await rfgSetup(app, id: "rfg_corpus")
            _ = try await rfgSubmission(
                app, id: "rfg_corpus_sub", setupID: try setup.requireID(), kind: APISubmission.Kind.classAggregate)
            try await markClaimedForResultReport("rfg_corpus_sub", on: app.db)
            let run = APIClassCoverageRun(testSetupID: "rfg_corpus", submissionID: "rfg_corpus_sub", contributors: [])
            try await run.save(on: app.db)

            let outcomes = [TestStatus.pass, .pass, .pass, .fail].enumerated().map { index, status in
                rfgOutcome(name: "case_\(index)", status: status)
            }
            let response = try await rfgPostReport(
                app, rfgCollection(submissionID: "rfg_corpus_sub", setupID: "rfg_corpus", outcomes: outcomes))
            #expect(response.status == .ok)

            let landed = try #require(try await APIClassCoverageRun.find(try run.requireID(), on: app.db))
            #expect(landed.coverage == 0.75)
            #expect(landed.completedAt != nil)
            let submission = try #require(try await APISubmission.find("rfg_corpus_sub", on: app.db))
            #expect(submission.status == SubmissionStatus.complete.rawValue)
            #expect(try await APIResult.query(on: app.db).filter(\.$submissionID == "rfg_corpus_sub").count() == 1)
        }
    }

    /// A tournament match, a composite reference render and a composite
    /// spare record their effects best effort. With no backing row, the
    /// report still lands: one result row, and the submission completes.
    @Test(arguments: [
        APISubmission.Kind.tournamentMatch, APISubmission.Kind.compositeReference,
        APISubmission.Kind.compositeSpare,
    ])
    func aBestEffortKindLandsItsResultWithNoBackingRow(_ kind: String) async throws {
        try await rfgWithApp { app in
            let setup = try await rfgSetup(app, id: "rfg_kind")
            _ = try await rfgSubmission(app, id: "rfg_kind_sub", setupID: try setup.requireID(), kind: kind)
            try await markClaimedForResultReport("rfg_kind_sub", on: app.db)

            let response = try await rfgPostReport(
                app,
                rfgCollection(
                    submissionID: "rfg_kind_sub", setupID: "rfg_kind",
                    outcomes: [rfgOutcome(name: "match", status: .pass)]))
            #expect(response.status == .ok)
            #expect(try response.content.decode(ReportResponse.self).received)

            let submission = try #require(try await APISubmission.find("rfg_kind_sub", on: app.db))
            #expect(submission.status == SubmissionStatus.complete.rawValue)
            #expect(try await APIResult.query(on: app.db).filter(\.$submissionID == "rfg_kind_sub").count() == 1)
        }
    }

    // MARK: - WorkerJobClaim on a store without SQL

    /// A store without SQL answers the idle probe and the pending count
    /// through Fluent, with the same answers as the SQL path, and refuses
    /// the claim, which needs SQL, without touching the row.
    @Test func aStoreWithoutSQLProbesThroughFluentAndRefusesTheClaim() async throws {
        try await rfgWithApp { app in
            let plain = ForwardingTestDatabase(base: app.db)
            #expect(try await WorkerJobClaim.hasPendingWork(on: plain) == false)
            #expect(try await WorkerJobClaim.pendingCount(on: plain) == 0)

            let setup = try await rfgSetup(app, id: "rfg_plain")
            let setupID = try setup.requireID()
            _ = try await rfgSubmission(app, id: "rfg_plain_a", setupID: setupID)
            _ = try await rfgSubmission(app, id: "rfg_plain_b", setupID: setupID)
            _ = try await rfgSubmission(
                app, id: "rfg_plain_done", setupID: setupID, status: SubmissionStatus.complete.rawValue)

            #expect(try await WorkerJobClaim.hasPendingWork(on: plain))
            #expect(try await WorkerJobClaim.pendingCount(on: plain) == 2)
            #expect(try await WorkerJobClaim.pendingCount(on: app.db) == 2)

            do {
                _ = try await WorkerJobClaim.claimSubmission(id: "rfg_plain_a", workerID: "plain-runner", db: plain)
                Issue.record("The claim on a store without SQL must throw")
            } catch WorkerJobError.internalInconsistency(let reason) {
                #expect(reason.contains("SQL"))
            }
            let row = try #require(try await APISubmission.find("rfg_plain_a", on: app.db))
            #expect(row.status == SubmissionStatus.pending.rawValue)
            #expect(row.workerID == nil)
        }
    }
}

// MARK: - Fixtures

private let rfgSecret = "runner-facing-gap-secret"

private let rfgWorkerManifest = """
    {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],\
    "testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
    """

/// One header case for the base URL test.
struct RFGHeaderCase: Sendable, CustomTestStringConvertible {
    let headers: [(String, String)]
    let expectedBase: String

    var testDescription: String { expectedBase + " from " + headers.map(\.0).joined(separator: ", ") }
}

private struct RFGErrorBody: Decodable {
    let error: String
}

private func rfgWithApp(
    appConfig: AppConfig? = nil, _ body: (Application) async throws -> Void
) async throws {
    try await withTestApp(prefix: "chickadee-rfg", appConfig: appConfig) { app in
        await app.workerSecretStore.setRuntimeOverride(rfgSecret)
        try await body(app)
    }
}

private func rfgSetup(
    _ app: Application, id: String, manifest: String = rfgWorkerManifest
) async throws -> APITestSetup {
    let course = APICourse(code: "RFG_\(id)", name: "Runner-facing", enrollmentMode: .closed)
    try await course.save(on: app.db)
    return try await makeTestSetup(
        on: app, id: id, courseID: try course.requireID(), manifest: manifest, withNotebook: false)
}

@discardableResult
private func rfgSubmission(
    _ app: Application, id: String, setupID: String, kind: String = APISubmission.Kind.student,
    status: String = SubmissionStatus.pending.rawValue
) async throws -> APISubmission {
    let submission = APISubmission(
        id: id, testSetupID: setupID, zipPath: app.submissionsDirectory + "\(id).zip",
        attemptNumber: 1, status: status, filename: "submission.zip", userID: nil, kind: kind)
    try await submission.save(on: app.db)
    return submission
}

private func rfgProfile(languages: [String]) -> RunnerCapabilityProfile {
    RunnerCapabilityProfile(
        platform: "linux", architecture: "x86_64",
        languageVersions: languages.map { LanguageVersion(language: $0, version: "1.0") },
        capabilities: [])
}

private func rfgActivityBody(
    workerID: String, hostname: String, profile: RunnerCapabilityProfile? = nil
) throws -> ByteBuffer {
    let payload = WorkerActivityPayload(
        workerID: workerID, hostname: hostname, runnerVersion: "runner-tests/1.0",
        maxConcurrentJobs: 1, activeJobs: 0, profile: profile)
    return ByteBuffer(data: try JSONEncoder().encode(payload))
}

private func rfgPoll(
    _ app: Application, workerID: String, hostname: String, profile: RunnerCapabilityProfile? = nil,
    extraHeaders: [(String, String)] = []
) async throws -> TestResponse {
    let path = "/api/v1/worker/request"
    let body = try rfgActivityBody(workerID: workerID, hostname: hostname, profile: profile)
    var headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: rfgSecret, workerID: workerID)
    for (name, value) in extraHeaders {
        headers.replaceOrAdd(name: name, value: value)
    }
    return try await app.asyncSendRequest(.POST, path) { req in
        req.headers = headers
        req.body = body
    }
}

private func rfgOutcome(name: String, status: TestStatus) -> TestOutcome {
    TestOutcome(
        testName: name, testClass: nil, tier: .pub, status: status, shortResult: status.rawValue,
        longResult: nil, score: status == .pass ? 1 : 0, executionTimeMs: 1, memoryUsageBytes: nil,
        attemptNumber: 1, isFirstPassSuccess: false)
}

private func rfgCollection(
    submissionID: String, setupID: String, outcomes: [TestOutcome] = []
) -> TestOutcomeCollection {
    let passed = outcomes.filter { $0.status == .pass }.count
    return TestOutcomeCollection(
        submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
        compilerOutput: nil, outcomes: outcomes, totalTests: outcomes.count, passCount: passed,
        failCount: outcomes.count - passed, errorCount: 0, timeoutCount: 0, executionTimeMs: 10,
        runnerVersion: "runner-tests/1.0", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
}

private func rfgReportBody(_ collection: TestOutcomeCollection) throws -> ByteBuffer {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return ByteBuffer(data: try encoder.encode(WorkerExecutionReport(collection: collection, diagnostics: nil)))
}

private func rfgPostReport(_ app: Application, _ collection: TestOutcomeCollection) async throws -> TestResponse {
    let path = "/api/v1/worker/results"
    let body = try rfgReportBody(collection)
    let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: rfgSecret)
    return try await app.asyncSendRequest(.POST, path) { req in
        req.headers = headers
        req.body = body
    }
}
