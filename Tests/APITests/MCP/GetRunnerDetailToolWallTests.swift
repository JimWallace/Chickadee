// Tests/APITests/MCP/GetRunnerDetailToolWallTests.swift
//
// get_runner_detail on the admin diagnostics MCP, for the cases that
// AdminMCPToolsTests does not reach: a blank runner id, a runner that the
// activity store no longer holds (the identity comes from its newest
// snapshot), the capability tags, and the gates in front of the tool (the
// diagnostics:read scope and the admin re-check, for a course instructor who
// is not a deployment admin). Every output is checked against the student-data
// wall: no per-job rows, no student id, no username, no submission id.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class GetRunnerDetailToolWallTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "admin-mcp-runner-detail")
    }

    private func context(
        subject: String, scopes: Set<DiagnosticScope> = [.read]
    ) -> AdminToolContext {
        adminMCPContext(app, subject: subject, scopes: scopes)
    }

    private var dispatcher: AdminMCPDispatcher {
        AdminMCPDispatcher(
            serverInfo: MCPServerInfo(name: "Chickadee Admin MCP", version: "test"),
            tools: AdminMCPToolCatalog.live)
    }

    private func callRequest(runnerID: String) -> JSONRPCRequest {
        JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object([
                "name": .string(GetRunnerDetailTool.name),
                "arguments": .object(["runnerID": .string(runnerID)]),
            ]))
    }

    private func saveSnapshot(
        runnerID: String, hostname: String, version: String, maxJobs: Int, age: TimeInterval
    ) async throws {
        try await RunnerSnapshot(
            runnerID: runnerID, recordedAt: Date().addingTimeInterval(-age), activeJobs: 1, maxJobs: maxJobs,
            availableCapacity: maxJobs - 1, hostname: hostname, runnerVersion: version, lastPollAt: nil,
            lastHeartbeatAt: nil, serverAssignedJobCountSinceStart: nil
        ).save(on: app.db)
    }

    /// A student's graded job on `runnerID`: a submission with `status` and
    /// one job metric. Returns the student id and the submission id, the two
    /// identifiers the tool must never show.
    private func saveStudentJob(
        runnerID: String, tag: String, status: String
    ) async throws -> (studentID: UUID, submissionID: String) {
        let course = try await makeTestCourse(on: app, code: "RDW\(tag)")
        let courseID = try course.requireID()
        let setupID = "setup_rdw_\(tag)"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let student = try await makeTestUser(on: app, username: "rdw_student_\(tag)")
        let studentID = try student.requireID()
        let submissionID = "sub_rdw_\(tag)"
        let submission = try await makeTestSubmission(
            on: app, id: submissionID, setupID: setupID, userID: studentID, status: status)
        submission.workerID = runnerID
        try await submission.update(on: app.db)
        let metric = JobExecutionMetric(
            submissionID: submissionID, jobID: submissionID, testSetupID: setupID, courseID: courseID,
            assignmentID: nil, userID: studentID, runnerID: runnerID, kind: "student", attemptNumber: 1,
            enqueuedAt: Date())
        metric.finalStatus = status == SubmissionStatus.complete.rawValue ? "passed" : "error"
        metric.executionMs = 800
        metric.completedAt = Date()
        try await metric.save(on: app.db)
        return (studentID, submissionID)
    }

    private func expectNoStudentData(
        in json: String, students: [(studentID: UUID, submissionID: String)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for student in students {
            #expect(!json.contains(student.studentID.uuidString), sourceLocation: sourceLocation)
            #expect(!json.contains(student.studentID.uuidString.lowercased()), sourceLocation: sourceLocation)
            #expect(!json.contains(student.submissionID), sourceLocation: sourceLocation)
        }
        #expect(!json.contains("rdw_student_"), sourceLocation: sourceLocation)
        for key in ["username", "userID", "userId", "submissionID", "submissionId", "jobs", "recentJobs"] {
            #expect(!json.contains("\"\(key)\""), "output carries a \(key) field", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Arguments

    @Test(arguments: ["", "   ", "\n\t"])
    func aBlankRunnerIDIsRefused(runnerID: String) async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rdw-admin-blank", role: "admin")
            await #expect(throws: MCPToolError.invalidArguments(detail: "runnerID must not be empty.")) {
                _ = try await GetRunnerDetailTool().execute(
                    .init(runnerID: runnerID, sampleSize: nil), self.context(subject: "rdw-admin-blank"))
            }
        }
    }

    // MARK: - A runner the activity store no longer holds

    /// The identity comes from the newest snapshot. The all-time job count is
    /// the runner's finished submissions (complete or failed) and nothing
    /// else, and the output names none of them.
    @Test func aRunnerKnownOnlyBySnapshotsResolvesFromTheNewest() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rdw-admin-hist", role: "admin")
            try await saveSnapshot(
                runnerID: "runner-hist", hostname: "old-host", version: "runner/1.0", maxJobs: 2, age: 7200)
            try await saveSnapshot(
                runnerID: "runner-hist", hostname: "new-host", version: "runner/2.0", maxJobs: 6, age: 4000)
            let done = try await saveStudentJob(
                runnerID: "runner-hist", tag: "a", status: SubmissionStatus.complete.rawValue)
            let failed = try await saveStudentJob(
                runnerID: "runner-hist", tag: "b", status: SubmissionStatus.failed.rawValue)
            let pending = try await saveStudentJob(
                runnerID: "runner-hist", tag: "c", status: SubmissionStatus.pending.rawValue)
            let elsewhere = try await saveStudentJob(
                runnerID: "runner-other", tag: "d", status: SubmissionStatus.complete.rawValue)

            let output = try await GetRunnerDetailTool().execute(
                .init(runnerID: "  runner-hist  ", sampleSize: nil), context(subject: "rdw-admin-hist"))

            #expect(output.runnerID == "runner-hist")
            #expect(output.hostname == "new-host")
            #expect(output.runnerVersion == "runner/2.0")
            #expect(output.maxConcurrentJobs == 6)
            #expect(output.activeJobs == 0)
            #expect(output.jobsProcessed == 2)
            #expect(output.recentSnapshots.count == 2)
            #expect(output.recentSnapshots.first?.utilizationPercent == 17)
            let firstSeen = try #require(output.firstSeenAt)
            #expect(firstSeen < Date().addingTimeInterval(-7000))
            // Three jobs ran on this runner; the fourth ran elsewhere.
            #expect(output.timing.sampleSize == 3)
            #expect(output.timing.passedCount == 1)
            #expect(output.timing.errorCount == 2)
            #expect(output.capabilities.isEmpty)

            let json = try #require(String(bytes: JSONEncoder().encode(output), encoding: .utf8))
            expectNoStudentData(in: json, students: [done, failed, pending, elsewhere])
        }
    }

    // MARK: - Capability tags

    @Test func theCapabilityTagsListPlatformArchitectureLanguagesAndCapabilities() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rdw-admin-tags", role: "admin")
            await app.workerActivityStore.markActive(
                workerID: "runner-tags-mcp", hostname: "tags-host", runnerVersion: "v3", maxConcurrentJobs: 2)
            _ = try await app.runnerProfiles.registerOrUpdate(
                runnerID: "runner-tags-mcp", displayName: "tags-host",
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "arm64",
                    languageVersions: [
                        LanguageVersion(language: "python", version: "3.12.1"),
                        LanguageVersion(language: "r", version: "4.4.0"),
                    ],
                    capabilities: [RunnerCapability(name: "numpy"), RunnerCapability(name: "sandbox")]
                ),
                seenAt: Date(), on: app.db)

            let output = try await GetRunnerDetailTool().execute(
                .init(runnerID: "runner-tags-mcp", sampleSize: nil), context(subject: "rdw-admin-tags"))

            #expect(output.hostname == "tags-host")
            #expect(output.capabilities == ["linux", "arm64", "python 3.12.1", "r 4.4.0", "numpy", "sandbox"])
        }
    }

    @Test func anEmptyPlatformAndArchitectureAreLeftOut() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rdw-admin-bare", role: "admin")
            await app.workerActivityStore.markActive(
                workerID: "runner-bare-mcp", hostname: "bare-host", runnerVersion: "v3", maxConcurrentJobs: 1)
            _ = try await app.runnerProfiles.registerOrUpdate(
                runnerID: "runner-bare-mcp", displayName: "bare-host",
                profile: RunnerCapabilityProfile(
                    platform: "", architecture: "", languageVersions: [], capabilities: [RunnerCapability(name: "java")]
                ),
                seenAt: Date(), on: app.db)

            let output = try await GetRunnerDetailTool().execute(
                .init(runnerID: "runner-bare-mcp", sampleSize: nil), context(subject: "rdw-admin-bare"))

            #expect(output.capabilities == ["java"])
        }
    }

    // MARK: - The gates in front of the tool

    @Test func aCallWithoutTheDiagnosticsReadScopeIsRefusedBeforeTheTool() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rdw-admin-noscope", role: "admin")
            try await saveSnapshot(runnerID: "runner-noscope", hostname: "ns-host", version: "v1", maxJobs: 1, age: 60)

            let response = try #require(
                await dispatcher.dispatch(
                    callRequest(runnerID: "runner-noscope"), context: context(subject: "rdw-admin-noscope", scopes: []))
            )

            #expect(response.result == nil)
            let error = try #require(response.error)
            #expect(error.code == JSONRPCError.insufficientScopeCode)
            #expect(error.data == .string(DiagnosticScope.read.rawValue))
        }
    }

    @Test func toolsListShowsTheToolOnlyWithTheReadScope() async throws {
        try await withApp(app) { _ in
            let list = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/list", params: nil)

            let without = try #require(await dispatcher.dispatch(list, context: context(subject: "x", scopes: [])))
            let with = try #require(await dispatcher.dispatch(list, context: context(subject: "x")))

            #expect(!Self.toolNames(in: without).contains(GetRunnerDetailTool.name))
            #expect(Self.toolNames(in: with).contains(GetRunnerDetailTool.name))
        }
    }

    /// A course instructor is not a deployment admin. With the scope granted,
    /// the admin re-check still refuses them, and the refusal names no runner
    /// data.
    @Test func aCourseInstructorWithTheScopeIsRefused() async throws {
        try await withApp(app) { app in
            let prof = try await makeTestUser(on: app, username: "rdw-course-prof", role: "user")
            let course = try await makeTestCourse(on: app, code: "RDWPROF")
            try await APICourseEnrollment(userID: prof.requireID(), courseID: course.requireID(), role: .instructor)
                .save(on: app.db)
            try await saveSnapshot(runnerID: "runner-prof", hostname: "secret-host", version: "v1", maxJobs: 1, age: 60)

            let response = try #require(
                await dispatcher.dispatch(
                    callRequest(runnerID: "runner-prof"), context: context(subject: "rdw-course-prof")))

            let fields = try #require(Self.objectFields(response.result))
            #expect(fields["isError"] == .bool(true))
            #expect(fields["structuredContent"] == nil)
            let json = try #require(String(bytes: JSONEncoder().encode(response), encoding: .utf8))
            #expect(json.contains("Not authorized"))
            #expect(!json.contains("secret-host"))
        }
    }

    /// Through the dispatcher, an admin gets the aggregate shape and nothing
    /// row-level: the output fields are exactly the identity, the tags, the
    /// timing summary and the snapshots.
    @Test func anAdminGetsOnlyTheAggregateFieldsThroughTheDispatcher() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "rdw-admin-dispatch", role: "admin")
            try await saveSnapshot(runnerID: "runner-disp", hostname: "disp-host", version: "v1", maxJobs: 4, age: 60)
            let job = try await saveStudentJob(
                runnerID: "runner-disp", tag: "e", status: SubmissionStatus.complete.rawValue)

            let response = try #require(
                await dispatcher.dispatch(
                    callRequest(runnerID: "runner-disp"), context: context(subject: "rdw-admin-dispatch")))

            let fields = try #require(Self.objectFields(response.result))
            #expect(fields["isError"] == .bool(false))
            let structured = try #require(Self.objectFields(fields["structuredContent"]))
            #expect(
                Set(structured.keys) == [
                    "runnerID", "hostname", "runnerVersion", "activeJobs", "maxConcurrentJobs", "jobsProcessed",
                    "lastActive", "firstSeenAt", "capabilities", "timing", "recentSnapshots",
                ])
            let timing = try #require(Self.objectFields(structured["timing"]))
            #expect(timing["sampleSize"] == .int(1))
            #expect(timing["passedCount"] == .int(1))
            let json = try #require(String(bytes: JSONEncoder().encode(response), encoding: .utf8))
            expectNoStudentData(in: json, students: [job])
        }
    }

    // MARK: - JSON helpers

    private static func objectFields(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let fields) = value { return fields }
        return nil
    }

    private static func toolNames(in response: JSONRPCResponse) -> [String] {
        guard case .array(let tools) = objectFields(response.result)?["tools"] else { return [] }
        return tools.compactMap { tool in
            guard case .string(let name) = objectFields(tool)?["name"] else { return nil }
            return name
        }
    }
}
