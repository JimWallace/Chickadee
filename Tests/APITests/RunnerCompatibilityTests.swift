import Fluent
import Foundation
import Testing
import XCTVapor

@testable import Core
@testable import APIServer

@Suite(.serialized) final class RunnerCompatibilityTests {
    private let workerSecret = "compatibility-secret"

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-rct")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    @Test func versionComparatorSupportsMinimumAndExactMatches() async throws {
        try await withApp(app) { _ in
            let comparator = VersionComparator()
            #expect(comparator.compare("3.11", "3.10") == .orderedDescending)
            #expect(comparator.compare("3.9", "3.10") == .orderedAscending)
            #expect(comparator.compare("6.0", "6.0") == .orderedSame)
            #expect(comparator.compare("6.0", "6.1") == .orderedAscending)

        }
    }

    @Test func capabilityAndLanguageMatchingReportsDetailedFailures() async throws {
        try await withApp(app) { _ in
            let matcher = CompatibilityMatcher()
            let runner = RunnerCapabilityProfile(
                platform: "linux",
                architecture: "x86_64",
                languageVersions: [
                    LanguageVersion(language: "python", version: "3.9"),
                    LanguageVersion(language: "swift", version: "6.0"),
                ],
                capabilities: [RunnerCapability(name: "numpy")]
            )
            let requirements = AssignmentRequirementSpec(
                requiredPlatform: "linux",
                requiredArchitecture: "x86_64",
                requiredLanguages: [
                    AssignmentLanguageRequirement(language: "python", minimumVersion: "3.10"),
                    AssignmentLanguageRequirement(language: "swift", exactVersion: "6.1"),
                    AssignmentLanguageRequirement(language: "r", minimumVersion: "4.2"),
                ],
                requiredCapabilities: [
                    RunnerCapability(name: "numpy"),
                    RunnerCapability(name: "pandas"),
                ]
            )

            let result = matcher.evaluate(runnerProfile: runner, requirements: requirements)
            #expect(result.isCompatible == false)
            #expect(result.reasons.contains("python version 3.9 < required 3.10"))
            #expect(result.reasons.contains("swift version 6.0 != required 6.1"))
            #expect(result.reasons.contains("missing language r"))
            #expect(result.reasons.contains("missing capability pandas"))

        }
    }

    @Test func platformAndArchitectureMatchingPassesWhenExactMatchExists() async throws {
        try await withApp(app) { _ in
            let matcher = CompatibilityMatcher()
            let runner = RunnerCapabilityProfile(
                platform: "linux",
                architecture: "arm64",
                languageVersions: [LanguageVersion(language: "python", version: "3.11.8")],
                capabilities: [RunnerCapability(name: "numpy"), RunnerCapability(name: "pandas")]
            )
            let requirements = AssignmentRequirementSpec(
                requiredPlatform: "linux",
                requiredArchitecture: "arm64",
                requiredLanguages: [AssignmentLanguageRequirement(language: "python", minimumVersion: "3.10")],
                requiredCapabilities: [RunnerCapability(name: "numpy")]
            )

            let result = matcher.evaluate(runnerProfile: runner, requirements: requirements)
            #expect(result.isCompatible)
            #expect(result.reasons.isEmpty)

        }
    }

    @Test func runnerProfileInsertedAndUpdatedOnHeartbeat() async throws {
        try await withApp(app) { _ in
            let initial = WorkerActivityPayload(
                workerID: "runner-profile",
                hostname: "runner-profile.local",
                runnerVersion: "runner/1.0",
                maxConcurrentJobs: 2,
                activeJobs: 0,
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "x86_64",
                    languageVersions: [LanguageVersion(language: "python", version: "3.11.8")],
                    capabilities: [RunnerCapability(name: "numpy")]
                )
            )
            try await sendHeartbeat(initial)

            let inserted = try await RunnerProfile.query(on: app.db)
                .filter(\.$runnerID == "runner-profile")
                .first()
            #expect(inserted?.platform == "linux")
            #expect(inserted?.capabilityProfile.capabilities.map(\.name) == ["numpy"])

            let updatedPayload = WorkerActivityPayload(
                workerID: "runner-profile",
                hostname: "runner-profile.local",
                runnerVersion: "runner/1.1",
                maxConcurrentJobs: 2,
                activeJobs: 1,
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "x86_64",
                    languageVersions: [LanguageVersion(language: "python", version: "3.12.0")],
                    capabilities: [RunnerCapability(name: "numpy"), RunnerCapability(name: "pandas")]
                )
            )
            try await sendHeartbeat(updatedPayload)

            let profiles = try await RunnerProfile.query(on: app.db)
                .filter(\.$runnerID == "runner-profile")
                .all()
            #expect(profiles.count == 1)
            #expect(profiles.first?.capabilityProfile.languageVersions.first?.version == "3.12.0")
            #expect(profiles.first?.capabilityProfile.capabilities.map(\.name) == ["numpy", "pandas"])
            #expect(profiles.first?.isActive == true)

        }
    }

    @Test func assignmentWithNoRequirementsRemainsAssignableWithoutProfile() async throws {
        try await withApp(app) { _ in
            let setup = try await makeSetup(id: "compat_setup_open")
            let assignment = try await makeAssignment(setupID: setup.requireID(), title: "No Requirements")
            _ = assignment
            let submission = try await makeSubmission(id: "compat_sub_open", setupID: setup.requireID())

            let response = try await requestJob(
                workerID: "runner-no-profile",
                profile: nil
            )
            #expect(response.status == .ok)
            #expect(try response.content.decode(Job.self).submissionID == submission.id)

        }
    }

    @Test func assignmentWithRequirementsBlockedOnIncompatibleRunner() async throws {
        try await withApp(app) { _ in
            let setup = try await makeSetup(id: "compat_setup_blocked")
            let assignment = try await makeAssignment(setupID: setup.requireID(), title: "Python Assignment")
            try await addRequirement(
                assignmentID: try assignment.requireID(),
                spec: AssignmentRequirementSpec(
                    requiredPlatform: "linux",
                    requiredArchitecture: "x86_64",
                    requiredLanguages: [AssignmentLanguageRequirement(language: "python", minimumVersion: "3.10")],
                    requiredCapabilities: [RunnerCapability(name: "numpy")]
                )
            )
            let submission = try await makeSubmission(id: "compat_sub_blocked", setupID: setup.requireID())

            let response = try await requestJob(
                workerID: "runner-incompatible",
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "x86_64",
                    languageVersions: [LanguageVersion(language: "python", version: "3.9")],
                    capabilities: []
                )
            )
            #expect(response.status == .noContent)

            let reloaded = try await APISubmission.find(try submission.requireID(), on: app.db)
            #expect(reloaded?.status == "pending")

        }
    }

    @Test func compatibleRunnerReceivesJobAfterIncompatibleRunnerSkipsIt() async throws {
        try await withApp(app) { _ in
            let setup = try await makeSetup(id: "compat_setup_claim")
            let assignment = try await makeAssignment(setupID: setup.requireID(), title: "Needs Pandas")
            try await addRequirement(
                assignmentID: try assignment.requireID(),
                spec: AssignmentRequirementSpec(
                    requiredPlatform: "linux",
                    requiredArchitecture: "arm64",
                    requiredLanguages: [AssignmentLanguageRequirement(language: "python", minimumVersion: "3.10")],
                    requiredCapabilities: [RunnerCapability(name: "pandas")]
                )
            )
            let submission = try await makeSubmission(id: "compat_sub_claim", setupID: setup.requireID())

            let firstResponse = try await requestJob(
                workerID: "runner-wrong-arch",
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "x86_64",
                    languageVersions: [LanguageVersion(language: "python", version: "3.11")],
                    capabilities: [RunnerCapability(name: "pandas")]
                )
            )
            #expect(firstResponse.status == .noContent)

            let secondResponse = try await requestJob(
                workerID: "runner-compatible",
                profile: RunnerCapabilityProfile(
                    platform: "linux",
                    architecture: "arm64",
                    languageVersions: [LanguageVersion(language: "python", version: "3.11")],
                    capabilities: [RunnerCapability(name: "pandas")]
                )
            )
            #expect(secondResponse.status == .ok)
            let secondSubmissionID = try secondResponse.content.decode(Job.self).submissionID
            let expectedID = try submission.requireID()
            #expect(secondSubmissionID == expectedID)

        }
    }

    private func requestJob(
        workerID: String,
        profile: RunnerCapabilityProfile?
    ) async throws -> XCTHTTPResponse {
        let path = "/api/v1/worker/request"
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: "\(workerID).local",
            runnerVersion: "runner-tests/1.0",
            maxConcurrentJobs: 1,
            activeJobs: 0,
            profile: profile
        )
        let body = ByteBuffer(data: try JSONEncoder().encode(payload))
        let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: workerSecret)
        return try await app.asyncSendRequest(.POST, path) { req in
            req.headers = headers
            req.body = body
        }
    }

    private func sendHeartbeat(_ payload: WorkerActivityPayload) async throws {
        let path = "/api/v1/worker/heartbeat"
        let body = ByteBuffer(data: try JSONEncoder().encode(payload))
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(
                    method: .POST,
                    path: path,
                    body: body,
                    workerSecret: self.workerSecret,
                    workerID: payload.workerID
                )
                req.body = body
            },
            afterResponse: { response in
                #expect(response.status == .ok)
            })
    }

    private func makeSetup(id: String) async throws -> APITestSetup {
        let course = APICourse(code: "COMP_\(id)", name: "Compatibility", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: id,
            manifest:
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#,
            zipPath: "/tmp/\(id).zip",
            courseID: try course.requireID()
        )
        try await setup.save(on: app.db)
        return setup
    }

    private func makeAssignment(setupID: String, title: String) async throws -> APIAssignment {
        guard let courseID = try await APITestSetup.find(setupID, on: app.db)?.courseID else {
            throw XCTSkip("missing course for setup")
        }
        let assignment = APIAssignment(testSetupID: setupID, title: title, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    private func addRequirement(assignmentID: UUID, spec: AssignmentRequirementSpec) async throws {
        let requirement = AssignmentRequirement(assignmentID: assignmentID, specification: spec)
        try await requirement.save(on: app.db)
    }

    private func makeSubmission(id: String, setupID: String) async throws -> APISubmission {
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
}
