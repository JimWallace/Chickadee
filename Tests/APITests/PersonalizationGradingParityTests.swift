// Tests/APITests/PersonalizationGradingParityTests.swift
//
// Browser/worker grading parity (the #809 regression class): for the same
// student and assignment, the browser seed endpoint and the worker job payload
// must resolve the SAME seed and the SAME per-student expression values. Both
// paths share `AssignmentSeedStore.ensureSeed` + `PersonalizationSubstitution.
// gradingInputs`; this test pins the end-to-end equality so a future change to
// either path (support-file dir, manifest decode, caching) can't silently
// diverge.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class PersonalizationGradingParityTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-parity")
        app.storage[WorkerClaimQueueKey.self] = WorkerClaimQueue()
        await app.workerSecretStore.setRuntimeOverride(workerSecret)
    }

    private let workerSecret = "test-parity-secret"

    /// Worker-mode manifest with a seed-dependent `=` expression, so the two
    /// paths only agree if they resolve the same seed AND evaluate it the same
    /// way (a constant expression would mask a seed mismatch).
    private let personalizedManifest = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],\
        "timeLimitSeconds":10,\
        "globalExpressions":[{"name":"k","expression":"seed % 9973"}]}
        """

    @Test func browserSeedEndpointAndWorkerJobResolveIdentically() async throws {
        try await withApp(app) { _ in
            // Personalized setup + open assignment in an auto-enroll course.
            let setupID = "parity_setup"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            try emptyZip.write(to: URL(fileURLWithPath: zipPath))
            let course = APICourse(code: "PAR101", name: "Parity Course", enrollmentMode: .auto)
            try await course.save(on: app.db)
            let setup = APITestSetup(
                id: setupID, manifest: personalizedManifest, zipPath: zipPath,
                courseID: try course.requireID())
            try await setup.save(on: app.db)
            let assignment = APIAssignment(
                testSetupID: setupID, title: "Parity", isOpen: true,
                courseID: try course.requireID())
            try await assignment.save(on: app.db)

            // Browser path: the student fetches the seed + resolved inputs.
            let cookie = try await loginUser(
                username: "parity_student", password: "pass", role: "student", on: app)
            var browserSeed: String?
            var browserInputs: [String: String]?
            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/seed",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let json =
                        try JSONSerialization.jsonObject(
                            with: Data(res.body.readableBytesView)) as? [String: Any]
                    browserSeed = json?["seed"] as? String
                    browserInputs = json?["personalizedInputs"] as? [String: String]
                })
            let seed = try #require(browserSeed, "personalized setup must return a seed")
            let inputs = try #require(browserInputs, "expressions must resolve to inputs")
            #expect(inputs["k"] != nil)

            // Worker path: the same student's pending submission is claimed and
            // the job payload carries the worker's resolution.
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "parity_student").first())
            let subZipPath = app.submissionsDirectory + "parity_sub.zip"
            try emptyZip.write(to: URL(fileURLWithPath: subZipPath))
            let submission = APISubmission(
                id: "parity_sub", testSetupID: setupID, zipPath: subZipPath,
                attemptNumber: 1, status: "pending",
                filename: "submission.zip", userID: try student.requireID(),
                kind: APISubmission.Kind.student)
            try await submission.save(on: app.db)

            let payload = WorkerActivityPayload(
                workerID: "parity-worker", hostname: "parity.local",
                runnerVersion: "runner-tests/1.0", maxConcurrentJobs: 1, activeJobs: 0,
                profile: nil)
            let body = ByteBuffer(data: try JSONEncoder().encode(payload))
            let path = "/api/v1/worker/request"
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHMACHeaders(
                        method: .POST, path: path, body: body, workerSecret: workerSecret)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "worker must claim the pending submission")
                    let job = try res.content.decode(Job.self)
                    #expect(
                        job.assignmentSeed == seed,
                        "worker and browser must resolve the same per-(student, assignment) seed")
                    #expect(
                        job.personalizedInputs == inputs,
                        "worker and browser must deliver identical personalized grading inputs")
                })
        }
    }
}
