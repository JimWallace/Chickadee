// Tests/APITests/RunnerDeploymentFloorTests.swift
//
// The deployment-wide minimum runner version (#1249): a floor under every
// job, beside the per-assignment `minimumRunnerVersion`. Pinned here: a real
// semver below the floor is refused, a version the comparator cannot parse is
// admitted (mock and third-party runners advertise such strings), and a
// manifest minimum above the floor still applies on top of it.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct RunnerDeploymentFloorGateTests {

    @Test func aRunnerBelowTheFloorIsRefusedWithAReason() {
        let result = RunnerVersionGate.evaluateDeploymentFloor(runnerVersion: "0.4.999", floor: "0.5.0")
        #expect(!result.isCompatible)
        #expect(result.reasons.contains { $0.contains("0.4.999") && $0.contains("deployment minimum 0.5.0") })
    }

    @Test(arguments: ["0.5.0", "0.5.241", "1.0.0"])
    func aRunnerAtOrAboveTheFloorIsAdmitted(runnerVersion: String) {
        let result = RunnerVersionGate.evaluateDeploymentFloor(runnerVersion: runnerVersion, floor: "0.5.0")
        #expect(result.isCompatible)
        #expect(result.reasons.isEmpty)
    }

    @Test(arguments: ["runner/1.0", "test", "", "shell-runner/1.0"])
    func anUnparseableRunnerVersionIsAdmitted(runnerVersion: String) {
        #expect(RunnerVersionGate.evaluateDeploymentFloor(runnerVersion: runnerVersion, floor: "0.5.0").isCompatible)
    }

    /// The shipped floor must itself parse, or the gate would admit every
    /// runner and the floor would be decoration.
    @Test func theShippedFloorParses() {
        #expect(RunnerVersionGate.isParseable(RunnerVersionGate.deploymentMinimumRunnerVersion))
        #expect(!RunnerVersionGate.evaluateDeploymentFloor(runnerVersion: "0.0.1").isCompatible)
    }

    /// The server never refuses its own build as a runner.
    @Test func theCurrentBuildMeetsTheShippedFloor() {
        #expect(RunnerVersionGate.evaluateDeploymentFloor(runnerVersion: ChickadeeVersion.current).isCompatible)
    }
}

@Suite(.serialized) final class RunnerDeploymentFloorClaimTests {
    private let workerSecret = "deployment-floor-secret"

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-rdf")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    @Test func anUngatedJobIsNotClaimedByARunnerBelowTheFloor() async throws {
        try await withApp(app) { _ in
            let submission = try await makeSubmission(id: "floor_sub_old", minimumRunnerVersion: nil)

            let response = try await requestJob(workerID: "runner-floor-old", runnerVersion: "0.4.999")
            #expect(response.status == .noContent)
            #expect(try await APISubmission.find(try submission.requireID(), on: app.db)?.status == "pending")
        }
    }

    @Test func anUngatedJobIsClaimedByARunnerAtTheFloor() async throws {
        try await withApp(app) { _ in
            let submission = try await makeSubmission(id: "floor_sub_ok", minimumRunnerVersion: nil)

            let response = try await requestJob(
                workerID: "runner-floor-ok", runnerVersion: RunnerVersionGate.deploymentMinimumRunnerVersion)
            #expect(response.status == .ok)
            #expect(try response.content.decode(Job.self).submissionID == submission.id)
        }
    }

    @Test func aManifestMinimumAboveTheFloorStillApplies() async throws {
        try await withApp(app) { _ in
            let submission = try await makeSubmission(id: "floor_sub_manifest", minimumRunnerVersion: "99.0.0")

            let atFloor = try await requestJob(
                workerID: "runner-floor-manifest", runnerVersion: RunnerVersionGate.deploymentMinimumRunnerVersion)
            #expect(atFloor.status == .noContent)

            let aboveBoth = try await requestJob(workerID: "runner-floor-new", runnerVersion: "99.0.0")
            #expect(aboveBoth.status == .ok)
            #expect(try aboveBoth.content.decode(Job.self).submissionID == submission.id)
        }
    }

    // MARK: - Helpers

    private func makeSubmission(id: String, minimumRunnerVersion: String?) async throws -> APISubmission {
        let course = APICourse(code: "FLOOR_\(id)", name: "Floor", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        var fields =
            #""schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10"#
        if let minimumRunnerVersion {
            fields += #","minimumRunnerVersion":"\#(minimumRunnerVersion)""#
        }
        let setupID = "\(id)_setup"
        try await APITestSetup(id: setupID, manifest: "{\(fields)}", zipPath: "/tmp/\(setupID).zip", courseID: courseID)
            .save(on: app.db)
        try await APIAssignment(testSetupID: setupID, title: "Floor \(id)", isOpen: true, courseID: courseID)
            .save(on: app.db)
        let submission = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: "/tmp/\(id).zip",
            attemptNumber: 1,
            status: "pending",
            filename: "submission.zip",
            userID: nil,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        return submission
    }

    private func requestJob(workerID: String, runnerVersion: String) async throws -> TestingHTTPResponse {
        let path = "/api/v1/worker/request"
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: "\(workerID).local",
            runnerVersion: runnerVersion,
            maxConcurrentJobs: 1,
            activeJobs: 0,
            profile: nil
        )
        let body = ByteBuffer(data: try JSONEncoder().encode(payload))
        let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: workerSecret)
        return try await app.asyncSendRequest(.POST, path) { req in
            req.headers = headers
            req.body = body
        }
    }
}
