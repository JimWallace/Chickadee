// Tests/APITests/WorkerRoutesTests.swift
//
// Integration tests for WorkerJobRoutes and WorkerArtifactRoutes:
//   POST /api/v1/worker/request                           — claim next pending job
//   GET  /api/v1/worker/submissions/:id/download          — stream submission zip
//   GET  /api/v1/worker/testsetups/:id/download           — stream test-setup zip

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

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
            throw IssueRecorded("setup missing course")
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
            let sub = try await makeSubmission(id: "wsub_01", setupID: (try setup.requireID()))

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
                    #expect(job.testSetupURL.path == "/api/v1/worker/testsetups/\((try setup.requireID()))/download")
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
            let firstSub = try await makeSubmission(id: "wsub_version_1", setupID: (try setup.requireID()))

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
            let secondSub = try await makeSubmission(id: "wsub_version_2", setupID: (try setup.requireID()))

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
            let sub = try await makeSubmission(
                id: "bsub_01", setupID: (try setup.requireID()), kind: APISubmission.Kind.student)

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
                id: "bsub_complete", setupID: (try setup.requireID()),
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
            let workerSub = try await makeSubmission(id: "mixed_wsub", setupID: (try workerSetup.requireID()))
            let browserSub = try await makeSubmission(id: "mixed_bsub", setupID: (try browserSetup.requireID()))

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
            #expect(allIDs.contains((try workerSub.requireID())))
            #expect(allIDs.contains((try browserSub.requireID())))

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
                id: "vsub_01", setupID: (try setup.requireID()),
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
                id: "psub_student", setupID: (try setup.requireID()),
                kind: APISubmission.Kind.student)
            _ = try await makeSubmission(
                id: "psub_val", setupID: (try setup.requireID()),
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
            _ = try await makeSubmission(id: "cc_sub", setupID: (try setup.requireID()))

            let path = "/api/v1/worker/request"
            let secret = workerSecret  // String — Sendable
            let testApp = app  // Application — @unchecked Sendable

            var responses: [TestingHTTPResponse] = []
            try await withThrowingTaskGroup(of: TestingHTTPResponse.self) { group in
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
            let retest = try await makeSubmission(id: "prio_retest", setupID: (try setup.requireID()))
            retest.submittedAt = earlier
            retest.retestedAt = now
            try await retest.save(on: app.db)

            // Fresh submission with a NEWER submittedAt — should still be claimed first.
            let fresh = try await makeSubmission(id: "prio_fresh", setupID: (try setup.requireID()))
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

            let olderRetest = try await makeSubmission(id: "rprio_r1", setupID: (try setup.requireID()))
            olderRetest.submittedAt = earlier
            olderRetest.retestedAt = now
            try await olderRetest.save(on: app.db)

            let newerRetest = try await makeSubmission(id: "rprio_r2", setupID: (try setup.requireID()))
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
            let sub = try await makeSubmission(id: "dlsub_01", setupID: (try setup.requireID()))

            let path = "/api/v1/worker/submissions/\((try sub.requireID()))/download"
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

    // A reference-solution (validation) notebook carrying `{{name}}`
    // personalization placeholders is substituted ONCE at enqueue
    // (`materializeValidationGrading`) into a `<zipPath>.grading` sidecar; the
    // download route then streams that sidecar verbatim (no eval on the hot
    // path). These tests drive `materializeValidationGrading` directly and
    // assert the download route is pure I/O.
    private let substManifestJSON = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,\
        "globalVariables":[{"name":"answer","value":"ck_subst_marker"}]}
        """

    private func makeNotebookSubmission(
        id: String, setupID: String, kind: String, source: String, userID: UUID? = nil
    ) async throws -> APISubmission {
        let nbURL = URL(fileURLWithPath: app.submissionsDirectory)
            .appendingPathComponent("\(id).ipynb")
        let notebook = """
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
            {"cell_type":"code","metadata":{},"execution_count":null,"outputs":[],"source":\(
                String(data: try JSONEncoder().encode(source), encoding: .utf8) ?? "\"\"")}]}
            """
        try Data(notebook.utf8).write(to: nbURL)
        let sub = APISubmission(
            id: id, testSetupID: setupID, zipPath: nbURL.path,
            attemptNumber: 1, status: "pending",
            filename: "solution.ipynb", userID: userID, kind: kind)
        try await sub.save(on: app.db)
        return sub
    }

    @Test func materializeValidation_writesSidecar_andDownloadStreamsIt() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "subst_setup_01", manifest: substManifestJSON)
            let setupID = try setup.requireID()
            let sub = try await self.makeNotebookSubmission(
                id: "subst_val_01", setupID: setupID,
                kind: APISubmission.Kind.validation, source: "x = {{answer}}")

            // Substitution happens at enqueue, NOT on the download hot path.
            let template = try Data(contentsOf: URL(fileURLWithPath: sub.zipPath))
            _ = await materializeValidationGrading(
                submission: sub, setupID: setupID, templateNotebookData: template,
                testSetupsDirectory: self.app.testSetupsDirectory, app: self.app,
                on: self.app.db)

            // The cache record is stamped on the row.
            #expect(sub.materializationJSON != nil)

            let path = "/api/v1/worker/submissions/subst_val_01/download"
            try await self.app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers = self.workerHeaders(method: .GET, path: path) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("ck_subst_marker"))
                    #expect(!res.body.string.contains("{{answer}}"))
                })
        }
    }

    @Test func downloadValidation_noSidecar_streamsTemplateVerbatim() async throws {
        // Without materialization there is no sidecar, so the download route
        // streams the stored template verbatim — pure I/O, never substituting
        // on this path (so it can't trip the runner's download timeout).
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "subst_setup_03", manifest: substManifestJSON)
            _ = try await self.makeNotebookSubmission(
                id: "subst_val_03", setupID: (try setup.requireID()),
                kind: APISubmission.Kind.validation, source: "x = {{answer}}")

            let path = "/api/v1/worker/submissions/subst_val_03/download"
            try await self.app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers = self.workerHeaders(method: .GET, path: path) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("{{answer}}"))
                })
        }
    }

    @Test func downloadSubmission_studentNotebook_leavesPlaceholdersVerbatim() async throws {
        // Student submissions are already-substituted working copies, so the
        // download path must NOT re-process them.
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "subst_setup_02", manifest: substManifestJSON)
            _ = try await self.makeNotebookSubmission(
                id: "subst_stu_01", setupID: (try setup.requireID()),
                kind: APISubmission.Kind.student, source: "x = {{answer}}")

            let path = "/api/v1/worker/submissions/subst_stu_01/download"
            try await self.app.asyncTest(
                .GET, path,
                beforeRequest: { req in req.headers = self.workerHeaders(method: .GET, path: path) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("{{answer}}"))
                })
        }
    }

    // The gap #869 missed: a per-student `=` EXPRESSION in the solution (not a
    // literal) must resolve at enqueue and land in the grading sidecar — with
    // the same seed feeding `_ck_inputs.py`. Requires a real seed (→ user +
    // assignment) and `python3`.
    @Test func materializeValidation_resolvesExpressionForSeed() async throws {
        try await withApp(app) { _ in
            // Keep the python3 skip-guard *inside* withApp so the test
            // Application is always shut down.  An early `return` before withApp
            // leaks the app, and its deinit then trips Vapor's
            // `ServeCommand did not shutdown before deinit` assertion → SIGILL,
            // which kills the whole test process (see TestHelpers.swift).
            let python3Paths = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
            guard python3Paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
                return  // python3 unavailable on this platform — skip
            }
            let manifest = """
                {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],\
                "timeLimitSeconds":10,\
                "globalExpressions":[{"name":"shift","expression":"1 + seed % 25"}]}
                """
            let setup = try await makeTestSetup(id: "subst_setup_expr", manifest: manifest)
            let setupID = try setup.requireID()
            _ = try await self.makeAssignment(setupID: setupID)
            let user = APIUser(username: "ck_val_user", passwordHash: "x", role: "student")
            try await user.save(on: self.app.db)

            let sub = try await self.makeNotebookSubmission(
                id: "subst_val_expr", setupID: setupID,
                kind: APISubmission.Kind.validation, source: "shift = {{shift}}",
                userID: try user.requireID())

            let template = try Data(contentsOf: URL(fileURLWithPath: sub.zipPath))
            _ = await materializeValidationGrading(
                submission: sub, setupID: setupID, templateNotebookData: template,
                testSetupsDirectory: self.app.testSetupsDirectory, app: self.app,
                on: self.app.db)

            // Sidecar carries the resolved int, not the raw placeholder.
            let sidecar = sub.zipPath + ".grading"
            let body = try String(contentsOf: URL(fileURLWithPath: sidecar), encoding: .utf8)
            #expect(!body.contains("{{shift}}"))
            #expect(body.range(of: #"shift = \d+"#, options: .regularExpression) != nil)

            // The same value is cached for _ck_inputs.py, keyed to one seed.
            let materialization = try #require(sub.decodedMaterialization())
            #expect(materialization.seedHex != nil)
            #expect(materialization.inputs["shift"] != nil)
        }
    }

    // MARK: - GET /api/v1/worker/testsetups/:id/download

    @Test func downloadTestSetup_existingFile_returns200() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "dlts_01", manifest: workerManifestJSON)

            let path = "/api/v1/worker/testsetups/\((try setup.requireID()))/download"
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

    // MARK: - Class-activity match jobs (docs/class-activities.md)

    private let opponentManifestJSON = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"match.sh"}],"timeLimitSeconds":10,"activity":{"kind":"beatTheInstructor","opponentFile":"bot.py"}}
        """

    private func profile(capabilities: [String]) -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: "linux", architecture: "x86_64",
            languageVersions: [], capabilities: capabilities.map { RunnerCapability(name: $0) })
    }

    /// The served job carries the opponent — file and a seed derived from the
    /// submission — while the sanitized manifest carries no activity block.
    @Test func requestJob_matchActivity_carriesTheOpponentOnTheJob() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_match", manifest: opponentManifestJSON)
            let sub = try await makeSubmission(id: "wsub_match", setupID: (try setup.requireID()))

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(
                workerID: "w-match", profile: profile(capabilities: [RunnerCapability.activityMatch.name]))
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
                    let opponent = try #require(job.opponent)
                    #expect(opponent.supportFile == "bot.py")
                    #expect(
                        opponent.matchSeed
                            == JobOpponent.matchSeed(
                                submissionID: try #require(sub.id),
                                opponentIdentity: JobOpponent.supportFileIdentity("bot.py")))
                    #expect(job.manifest.activity == nil)
                })
        }
    }

    /// Neither an ordinary assignment nor a bot kind with no file chosen
    /// carries an opponent: the second is the slice-1 path, unchanged.
    @Test(arguments: [
        #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#,
        #"{"schemaVersion":1,"testSuites":[{"tier":"public","script":"match.sh"}],"timeLimitSeconds":10,"activity":{"kind":"beatTheInstructor"}}"#,
    ])
    func requestJob_withoutAChosenOpponent_carriesNoOpponent(manifestJSON: String) async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_plain", manifest: manifestJSON)
            _ = try await makeSubmission(id: "wsub_plain", setupID: (try setup.requireID()))

            let path = "/api/v1/worker/request"
            let body = try workerRequestBody(workerID: "w-plain")
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: body)
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.opponent == nil)
                })
        }
    }

    /// A runner whose profile lacks `activity-match` never claims a match job
    /// (it would grade the bot match with no bot); the job waits for one that
    /// advertises it.
    @Test func requestJob_matchActivity_waitsForARunnerThatCanStageTheOpponent() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_gate", manifest: opponentManifestJSON)
            let sub = try await makeSubmission(id: "wsub_gate", setupID: (try setup.requireID()))

            let path = "/api/v1/worker/request"
            let oldBody = try workerRequestBody(
                workerID: "w-old", profile: profile(capabilities: ["shell-bash"]))
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: oldBody)
                    req.body = oldBody
                },
                afterResponse: { res in
                    #expect(res.status == .noContent, "an old build must not claim a match job")
                })
            let stillPending = try await APISubmission.find(sub.id, on: app.db)
            #expect(stillPending?.status == "pending")

            let newBody = try workerRequestBody(
                workerID: "w-new", profile: profile(capabilities: [RunnerCapability.activityMatch.name]))
            try await app.asyncTest(
                .POST, path,
                beforeRequest: { req in
                    req.headers = workerHeaders(method: .POST, path: path, body: newBody)
                    req.body = newBody
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let job = try res.content.decode(Job.self)
                    #expect(job.submissionID == sub.id)
                })
            let claimed = try await APISubmission.find(sub.id, on: app.db)
            #expect(claimed?.workerID == "w-new")
        }
    }

    // MARK: - King of the hill (docs/class-activities.md, slice 3)

    private let hillManifestJSON = """
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"match.sh"}],"timeLimitSeconds":10,"activity":{"kind":"kingOfTheHill","opponentFile":"bot.py"}}
        """

    private func hillProfile() -> RunnerCapabilityProfile {
        profile(capabilities: [RunnerCapability.activityMatch.name, RunnerCapability.activityOpponentSubmission.name])
    }

    private func requestJob(workerID: String, profile: RunnerCapabilityProfile?) async throws -> Job? {
        let path = "/api/v1/worker/request"
        let body = try workerRequestBody(workerID: workerID, profile: profile)
        var job: Job?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHeaders(method: .POST, path: path, body: body)
                req.body = body
            },
            afterResponse: { res in
                if res.status == .ok { job = try res.content.decode(Job.self) }
            })
        return job
    }

    /// With nobody on the hill the challenger plays the bot, and the claim
    /// opens the match row the result path will complete.
    @Test func requestJob_hill_playsTheBotUntilAStudentHoldsIt() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_hill1", manifest: hillManifestJSON)
            let sub = try await makeSubmission(id: "wsub_hill1", setupID: (try setup.requireID()))
            let job = try #require(try await requestJob(workerID: "w-hill", profile: hillProfile()))
            #expect(job.submissionID == sub.id)
            let opponent = try #require(job.opponent)
            #expect(opponent.supportFile == "bot.py")
            #expect(!opponent.stagesASubmission)
            let row = try #require(
                try await APIMatchResult.query(on: app.db).filter(\.$submissionID == "wsub_hill1").first())
            #expect(row.opponentIdentity == JobOpponent.supportFileIdentity("bot.py"))
            #expect(row.completedAt == nil)
            #expect(row.seed == opponent.matchSeed)
        }
    }

    /// With a champion, the challenger's job carries the champion's
    /// submission — its download URL and filename — and never the bot.
    @Test func requestJob_hill_carriesTheChampionsSubmission() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_hill2", manifest: hillManifestJSON)
            let champ = try await makeSubmission(id: "wsub_champ", setupID: (try setup.requireID()), status: "complete")
            champ.filename = "strategy.py"
            try await champ.save(on: app.db)
            let holder = try await makeTestUser(on: app, username: "hill_holder", role: "student")
            try await APIActivityChampion(
                testSetupID: try setup.requireID(), userID: try holder.requireID(),
                submissionID: "wsub_champ", crownedAt: Date()
            ).save(on: app.db)
            let sub = try await makeSubmission(id: "wsub_hill2", setupID: (try setup.requireID()))

            let job = try #require(try await requestJob(workerID: "w-hill2", profile: hillProfile()))
            #expect(job.submissionID == sub.id)
            let opponent = try #require(job.opponent)
            #expect(opponent.supportFile == nil)
            #expect(opponent.submissionID == "wsub_champ")
            #expect(opponent.submissionFilename == "strategy.py")
            #expect(opponent.submissionURL?.path == "/api/v1/worker/submissions/wsub_champ/download")
            #expect(
                opponent.matchSeed
                    == JobOpponent.matchSeed(
                        submissionID: "wsub_hill2", opponentIdentity: JobOpponent.submissionIdentity("wsub_champ")))
            let row = try #require(
                try await APIMatchResult.query(on: app.db).filter(\.$submissionID == "wsub_hill2").first())
            #expect(row.opponentSubmissionID == "wsub_champ")
        }
    }

    /// A slice-2 build (activity-match only) never claims a hill job.
    @Test func requestJob_hill_waitsForARunnerThatStagesSubmissions() async throws {
        try await withApp(app) { _ in
            let setup = try await makeTestSetup(id: "wsetup_hill3", manifest: hillManifestJSON)
            _ = try await makeSubmission(id: "wsub_hill3", setupID: (try setup.requireID()))
            let old = try await requestJob(
                workerID: "w-old-hill", profile: profile(capabilities: [RunnerCapability.activityMatch.name]))
            #expect(old == nil)
            let new = try await requestJob(workerID: "w-new-hill", profile: hillProfile())
            #expect(new?.submissionID == "wsub_hill3")
        }
    }
}
