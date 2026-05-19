// Tests/APITests/WorkerRoutesTests.swift
//
// Integration tests for WorkerJobRoutes and WorkerArtifactRoutes:
//   POST /api/v1/worker/request                           — claim next pending job
//   GET  /api/v1/worker/submissions/:id/download          — stream submission zip
//   GET  /api/v1/worker/testsetups/:id/download           — stream test-setup zip

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class WorkerRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-worker")

        // Initialize the claim queue before requests start (mirrors configure() eager-init pattern).
        app.storage[WorkerClaimQueueKey.self] = WorkerClaimQueue()
        // Set the shared secret so WorkerHMACAuthMiddleware validates signed requests
        await app.workerSecretStore.setRuntimeOverride(workerSecret)
    }

    private let workerSecret = "test-worker-secret-abc123"

    // Minimal worker-mode manifest JSON (gradingMode defaults to .worker)
    private let workerManifestJSON = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    // Browser-mode manifest JSON
    private let browserManifestJSON = """
        {"schemaVersion":1,"gradingMode":"browser","testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    // MARK: - Helpers

    private func workerHeaders(method: HTTPMethod = .POST, path: String, body: ByteBuffer? = nil) -> HTTPHeaders {
        workerHMACHeaders(method: method, path: path, body: body, workerSecret: workerSecret)
    }

    private func workerRequestBody(
        workerID: String,
        hostname: String? = nil,
        runnerVersion: String = "runner-tests/1.0",
        maxConcurrentJobs: Int = 1,
        activeJobs: Int = 0,
        profile: RunnerCapabilityProfile? = nil
    ) throws -> ByteBuffer {
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: hostname ?? "\(workerID).local",
            runnerVersion: runnerVersion,
            maxConcurrentJobs: maxConcurrentJobs,
            activeJobs: activeJobs,
            profile: profile
        )
        return ByteBuffer(data: try JSONEncoder().encode(payload))
    }

    private func makeDummyZip(named filename: String, in dir: URL) throws -> String {
        let data = Data("PK\0\0".utf8)  // minimal fake zip content
        let path = dir.appendingPathComponent(filename).path
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeTestSetup(id: String, manifest: String) async throws -> APITestSetup {
        let zipPath = try makeDummyZip(
            named: "\(id).zip",
            in: URL(fileURLWithPath: app.testSetupsDirectory))
        // Each test setup needs a course (FK constraint); create a throw-away one.
        let course = APICourse(code: "WK_\(id)", name: "Worker Test Course", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: id, manifest: manifest, zipPath: zipPath,
            courseID: try course.requireID())
        try await setup.save(on: app.db)
        return setup
    }

    private func makeSubmission(
        id: String, setupID: String, status: String = "pending",
        kind: String = APISubmission.Kind.student
    ) async throws -> APISubmission {
        let zipPath = try makeDummyZip(
            named: "\(id).zip",
            in: URL(fileURLWithPath: app.submissionsDirectory))
        let sub = APISubmission(
            id: id, testSetupID: setupID, zipPath: zipPath,
            attemptNumber: 1, status: status,
            filename: "submission.zip", userID: nil, kind: kind)
        try await sub.save(on: app.db)
        return sub
    }

    private func makeAssignment(setupID: String, title: String = "Assignment") async throws -> APIAssignment {
        guard let courseID = try await APITestSetup.find(setupID, on: app.db)?.courseID else {
            throw XCTSkip("setup missing course")
        }
        let assignment = APIAssignment(testSetupID: setupID, title: title, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    private func addRequirement(
        assignmentID: UUID,
        spec: AssignmentRequirementSpec
    ) async throws {
        let requirement = AssignmentRequirement(assignmentID: assignmentID, specification: spec)
        try await requirement.save(on: app.db)
    }

    // MARK: - Auth tests

    @Test func requestJob_missingSecret_returns401() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(
                .POST, "/api/v1/worker/request",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = try self.workerRequestBody(workerID: "w1")
                },
                afterResponse: { res in
                    #expect(res.status == .unauthorized)
                })

        }
    }

    @Test func requestJob_wrongSecret_returns401() async throws {
        try await withApp(app) { _ in
            // Sending a bad/absent signature should still yield 401
            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w1")
            var badHeaders = workerHMACHeaders(
                method: .POST, path: path, body: body,
                workerSecret: "wrong-secret")
            badHeaders.contentType = .json
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = badHeaders
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .unauthorized)
                })

        }
    }

    @Test func downloadSubmission_missingSecret_returns401() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(.GET, "/api/v1/worker/submissions/sub1/download") { res in
                #expect(res.status == .unauthorized)
            }

        }
    }

    @Test func downloadTestSetup_missingSecret_returns401() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(.GET, "/api/v1/worker/testsetups/setup1/download") { res in
                #expect(res.status == .unauthorized)
            }

        }
    }

    // MARK: - POST /api/v1/worker/request

    @Test func requestJob_noPendingJobs_returns204() async throws {
        try await withApp(app) { _ in
            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w1")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                })

        }
    }

    @Test func requestJob_pendingWorkerModeStudent_returnsJob() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_01", manifest: workerManifestJSON)
            let sub = try await makeSubmission(id: "wsub_01", setupID: setup.id!)

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w1")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == sub.id)
                    #expect(job.testSetupID == setup.id)
                    #expect(job.attemptNumber == 1)
                    #expect(job.testSetupURL.path == "/api/v1/worker/testsetups/\(setup.id!)/download")
                    #expect(
                        URLComponents(url: job.testSetupURL, resolvingAgainstBaseURL: false)?
                            .queryItems?
                            .first(where: { $0.name == "v" })?
                            .value != nil)
                })

            // Submission should now be "assigned"
            let updated = try await APISubmission.find(sub.id, on: app.db)
            #expect(updated?.status == "assigned")
            #expect(updated?.workerID == "w1")

        }
    }

    @Test func requestJobTestSetupVersionChangesWhenZipContentsChangeWithoutSizeChanging() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_version", manifest: workerManifestJSON)
            try Data("print('A')\n".utf8).write(to: URL(fileURLWithPath: setup.zipPath))
            let firstSub = try await makeSubmission(id: "wsub_version_1", setupID: setup.id!)

            let path = "/api/v1/worker/request"
            let firstBody = try workerRequestBody(workerID: "w-version-1")
            var firstVersion: String?
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: firstBody)
                    req.body = firstBody
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == firstSub.id)
                    firstVersion =
                        URLComponents(url: job.testSetupURL, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "v" })?
                        .value
                })

            try Data("print('B')\n".utf8).write(to: URL(fileURLWithPath: setup.zipPath))
            let secondSub = try await makeSubmission(id: "wsub_version_2", setupID: setup.id!)

            let secondBody = try workerRequestBody(workerID: "w-version-2")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: secondBody)
                    req.body = secondBody
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == secondSub.id)
                    let secondVersion = URLComponents(url: job.testSetupURL, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "v" })?
                        .value
                    #expect(firstVersion != nil)
                    #expect(secondVersion != nil)
                    #expect(firstVersion != secondVersion)
                })

        }
    }

    @Test func requestJob_browserModePendingStudent_claimedAsBackstop() async throws {
        try await withApp(app) { _ in
            // Browser-mode pending submissions ARE claimed by the worker as a backstop
            // (e.g., browser runner failed, timed out, or these are pre-fix stuck submissions).
            let setup = try await makeTestSetup(id: "bsetup_01", manifest: browserManifestJSON)
            let sub = try await makeSubmission(id: "bsub_01", setupID: setup.id!, kind: APISubmission.Kind.student)

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w1")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "Worker must claim browser-mode pending submissions as backstop")
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == sub.id)
                })

            // Submission should now be "assigned" to the worker
            let updated = try await APISubmission.find(sub.id, on: app.db)
            #expect(updated?.status == "assigned")
            #expect(updated?.workerID == "w1")

        }
    }

    @Test func requestJob_browserModeAlreadyComplete_notReclaimed() async throws {
        try await withApp(app) { _ in
            // A submission already completed by the browser runner must never be reclaimed.
            // The worker should only see "pending" submissions; "complete" ones are invisible.
            let setup = try await makeTestSetup(id: "bsetup_02", manifest: browserManifestJSON)
            _ = try await makeSubmission(
                id: "bsub_complete", setupID: setup.id!,
                status: "complete", kind: APISubmission.Kind.student)

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w1")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(
                        res.status == .noContent, "Already-complete browser submission must not be reclaimed by worker")
                })

        }
    }

    @Test func requestJob_browserAndWorkerMixed_bothClaimable_noContention() async throws {
        try await withApp(app) { _ in
            // Both browser-mode and worker-mode pending submissions are claimable.
            // Two sequential worker polls should each claim one; no double-claiming.
            let workerSetup = try await makeTestSetup(id: "mixed_wsetup", manifest: workerManifestJSON)
            let browserSetup = try await makeTestSetup(id: "mixed_bsetup", manifest: browserManifestJSON)
            let workerSub = try await makeSubmission(id: "mixed_wsub", setupID: workerSetup.id!)
            let browserSub = try await makeSubmission(id: "mixed_bsub", setupID: browserSetup.id!)

            let path = "/api/v1/worker/request"

            // First poll — claims the student submission (submitted first by sort order).
            let body1 = try workerRequestBody(workerID: "w1")
            var firstJobID: String?
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body1)
                    req.body = body1
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    firstJobID = try res.content.decode(Job.self).submissionID
                })

            // Second poll — claims the remaining submission.
            let body2 = try workerRequestBody(workerID: "w2")
            var secondJobID: String?
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body2)
                    req.body = body2
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    secondJobID = try res.content.decode(Job.self).submissionID
                })

            // Both submissions should be claimed, each by a different worker.
            let allIDs = Set([firstJobID, secondJobID].compactMap { $0 })
            #expect(allIDs.count == 2, "Both submissions must be claimed exactly once")
            #expect(allIDs.contains(workerSub.id!))
            #expect(allIDs.contains(browserSub.id!))

            // Third poll — nothing left.
            let body3 = try workerRequestBody(workerID: "w3")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body3)
                    req.body = body3
                },
                afterResponse: { res in
                    #expect(res.status == .noContent, "Queue must be empty after both submissions are claimed")
                })

        }
    }

    @Test func requestJob_pendingValidation_returnsJob() async throws {
        try await withApp(app) { _ in
            // Validation submissions are always worker-mode regardless of manifest gradingMode
            let setup = try await makeTestSetup(id: "vsetup_01", manifest: workerManifestJSON)
            let sub = try await makeSubmission(
                id: "vsub_01", setupID: setup.id!,
                kind: APISubmission.Kind.validation)

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w2")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == sub.id)
                })

        }
    }

    @Test func requestJob_studentPreferredOverValidation() async throws {
        try await withApp(app) { _ in
            // Worker-mode student submission should be returned before a validation submission
            let setup = try await makeTestSetup(id: "psetup_01", manifest: workerManifestJSON)
            let student = try await makeSubmission(
                id: "psub_student", setupID: setup.id!,
                kind: APISubmission.Kind.student)
            _ = try await makeSubmission(
                id: "psub_val", setupID: setup.id!,
                kind: APISubmission.Kind.validation)

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w3")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == student.id, "Student submission should be preferred over validation")
                })

        }
    }

    @Test func requestJob_concurrentClaims_onlyOneSucceeds() async throws {
        try await withApp(app) { _ in
            // One pending submission; two workers race to claim it.
            // The transaction in requestJob must ensure only one succeeds.
            let setup = try await makeTestSetup(id: "cc_setup", manifest: workerManifestJSON)
            _ = try await makeSubmission(id: "cc_sub", setupID: setup.id!)

            let path = "/api/v1/worker/request"
            let secret = workerSecret  // String — Sendable
            let testApp = app  // Application — @unchecked Sendable

            var responses: [XCTHTTPResponse] = []
            try await withThrowingTaskGroup(of: XCTHTTPResponse.self) { group in
                for workerID in ["w1", "w2"] {
                    // Compute per-worker values outside the task so the closure
                    // captures only Sendable types and avoids capturing `self`.
                    let body = try self.workerRequestBody(workerID: workerID)
                    let headers = workerHMACHeaders(
                        method: .POST, path: path,
                        body: body, workerSecret: secret)
                    group.addTask {
                        return try await testApp.asyncSendRequest(.POST, path) { req in
                            req.headers = headers
                            req.body = body
                        }
                    }
                }
                for try await response in group {
                    responses.append(response)
                }
            }

            #expect(responses.count == 2)
            let statuses = responses.map(\.status)
            #expect(statuses.contains(.ok), "One worker must claim the job")
            #expect(statuses.contains(.noContent), "The other worker must find nothing")

            // The submission must be owned by exactly one worker.
            let updated = try await APISubmission.find("cc_sub", on: app.db)
            #expect(updated?.status == "assigned")
            #expect(updated?.workerID != nil)

        }
    }

    @Test func requestJob_freshSubmissionClaimedAheadOfOlderRetest() async throws {
        try await withApp(app) { _ in
            // Even when a retest has an older submittedAt, a fresh student
            // submission must be claimed first so manifest-revision sweeps
            // can't starve active students (#427).
            let setup = try await makeTestSetup(id: "prio_setup", manifest: workerManifestJSON)

            let now = Date()
            let earlier = now.addingTimeInterval(-3600)
            let later = now.addingTimeInterval(-60)

            // Retest with the OLDER submittedAt (would win under pure FIFO).
            let retest = try await makeSubmission(id: "prio_retest", setupID: setup.id!)
            retest.submittedAt = earlier
            retest.retestedAt = now
            try await retest.save(on: app.db)

            // Fresh submission with a NEWER submittedAt — should still be claimed first.
            let fresh = try await makeSubmission(id: "prio_fresh", setupID: setup.id!)
            fresh.submittedAt = later
            try await fresh.save(on: app.db)

            let path = "/api/v1/worker/request"
            let body1 = try workerRequestBody(workerID: "w1")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body1)
                    req.body = body1
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(
                        job.submissionID == fresh.id,
                        "Fresh submission must be claimed before retest, regardless of submittedAt order")
                })

            // Second poll should now drain the retest.
            let body2 = try workerRequestBody(workerID: "w2")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body2)
                    req.body = body2
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == retest.id, "Retest must be claimed once fresh work has drained")
                })

        }
    }

    @Test func requestJob_amongRetests_oldestSubmittedAtFirst() async throws {
        try await withApp(app) { _ in
            // With no fresh work, retests drain in submittedAt order (oldest first).
            let setup = try await makeTestSetup(id: "rprio_setup", manifest: workerManifestJSON)

            let now = Date()
            let earlier = now.addingTimeInterval(-3600)
            let later = now.addingTimeInterval(-60)

            let olderRetest = try await makeSubmission(id: "rprio_r1", setupID: setup.id!)
            olderRetest.submittedAt = earlier
            olderRetest.retestedAt = now
            try await olderRetest.save(on: app.db)

            let newerRetest = try await makeSubmission(id: "rprio_r2", setupID: setup.id!)
            newerRetest.submittedAt = later
            newerRetest.retestedAt = now
            try await newerRetest.save(on: app.db)

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w1")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(
                        job.submissionID == olderRetest.id,
                        "Among retests with no fresh work, oldest submittedAt is claimed first")
                })

        }
    }

    // MARK: - GET /api/v1/worker/submissions/:id/download

    @Test func downloadSubmission_existingFile_returns200() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "dlsetup_01", manifest: workerManifestJSON)
            let sub = try await makeSubmission(id: "dlsub_01", setupID: setup.id!)

            let path = "/api/v1/worker/submissions/\(sub.id!)/download"
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .GET, path: path)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

        }
    }

    @Test func downloadSubmission_notFound_returns404() async throws {
        try await withApp(app) { _ in
            let path = "/api/v1/worker/submissions/nonexistent/download"
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .GET, path: path)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - GET /api/v1/worker/testsetups/:id/download

    @Test func downloadTestSetup_existingFile_returns200() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "dlts_01", manifest: workerManifestJSON)

            let path = "/api/v1/worker/testsetups/\(setup.id!)/download"
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .GET, path: path)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

        }
    }

    @Test func downloadTestSetup_notFound_returns404() async throws {
        try await withApp(app) { _ in
            let path = "/api/v1/worker/testsetups/nonexistent/download"
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .GET, path: path)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }
}
