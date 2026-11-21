// Tests/APITests/Grading/UnclaimableJobsRuleTests.swift
//
// Runners update only after they drain, so a runner behind the server is
// normal for a while. The alert that matters is for jobs that wait because no
// online runner may grade them. These tests prove that the rule fires for
// exactly those jobs, by the claim walk's own decision, names the reason, and
// stays quiet with no runner online; that the activity store's read for it
// prunes nothing; and that the skew alert's default grace covers an update
// job and a drain.
//
// `UnclaimableJobsEvaluationTests` covers the read that feeds the pure
// `decideUnclaimableJobs`, `evaluateUnclaimableJobs`, on the test database:
// which jobs count as waiting (pending, and older than the minimum wait from
// the retest time when there is one), how the online runners get their
// profiles, how an assignment's requirement reaches the decision, and how the
// summary names each blocked test setup.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct UnclaimableJobsRuleTests {

    private func manifest(minimumRunnerVersion: String? = nil) throws -> TestProperties {
        let minimum = minimumRunnerVersion.map { #", "minimumRunnerVersion": "\#($0)""# } ?? ""
        let json =
            #"{"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [], "#
            + #""testSuites": [{"tier": "public", "script": "test.sh"}], "timeLimitSeconds": 10, "makefile": null"#
            + minimum + "}"
        return try #require(decodeManifest(fromJSON: json))
    }

    private func group(
        _ id: String, minimumRunnerVersion: String? = nil, jobs: Int = 1, waited: TimeInterval = 600
    )
        throws -> WaitingJobGroup
    {
        WaitingJobGroup(
            testSetupID: id, manifest: try manifest(minimumRunnerVersion: minimumRunnerVersion),
            requirements: nil, jobCount: jobs, oldestWaitSeconds: waited)
    }

    private func runner(_ id: String, _ version: String) -> OnlineRunner {
        OnlineRunner(workerID: id, runnerVersion: version, profile: nil)
    }

    @Test func jobsThatNeedANewerRunnerThanAnyOnlineFireWithTheReason() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [try group("setup-new", minimumRunnerVersion: "0.5.500", jobs: 3, waited: 720)],
            runners: [runner("Sparrow", "0.5.499"), runner("Starling", "0.5.498")])
        #expect(evaluation.isFiring)
        #expect(evaluation.details["blocked_jobs"] == "3")
        #expect(evaluation.details["blocked_test_setups"] == "setup-new")
        #expect(evaluation.details["online_runners"] == "Sparrow,Starling")
        #expect(evaluation.summary.contains("0.5.500"), "the reason names the minimum: \(evaluation.summary)")
        #expect(evaluation.summary.contains("oldest 12 min"))
    }

    @Test func oneOnlineRunnerThatCanGradeTheJobsKeepsItQuiet() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [try group("setup-new", minimumRunnerVersion: "0.5.500")],
            runners: [runner("Sparrow", "0.5.499"), runner("Chickadee", "0.5.500")])
        #expect(!evaluation.isFiring)
    }

    @Test func onlyTheBlockedGroupsAreCounted() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [
                try group("setup-plain", jobs: 5),
                try group("setup-new", minimumRunnerVersion: "0.5.500", jobs: 2),
            ],
            runners: [runner("Sparrow", "0.5.499")])
        #expect(evaluation.isFiring)
        #expect(evaluation.details["blocked_jobs"] == "2")
        #expect(evaluation.details["blocked_test_setups"] == "setup-new")
    }

    /// The runner-offline rule covers a fleet with no runner up.
    @Test func noRunnerOnlineKeepsItQuiet() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [try group("setup-new", minimumRunnerVersion: "0.5.500")], runners: [])
        #expect(!evaluation.isFiring)
    }

    @Test func noWaitingJobKeepsItQuiet() {
        #expect(!decideUnclaimableJobs(groups: [], runners: [runner("Sparrow", "0.5.499")]).isFiring)
    }

    /// The rule and the claim walk must agree: a job the rule calls blocked is
    /// one that `claimCompatibility`, the claim walk's decision, refuses.
    @Test func theRuleUsesTheClaimDecision() throws {
        let job = try manifest(minimumRunnerVersion: "0.5.500")
        let refused = claimCompatibility(
            runnerVersion: "0.5.499", runnerProfile: nil, manifest: job, requirements: nil)
        let accepted = claimCompatibility(
            runnerVersion: "0.5.500", runnerProfile: nil, manifest: job, requirements: nil)
        #expect(!refused.isCompatible)
        #expect(accepted.isCompatible)
    }

    /// The rule reads the store with a short window. That read must not drop a
    /// runner that another reader, with a longer window, still needs.
    @Test func readingTheOnlineRunnersPrunesNothing() async {
        let store = WorkerActivityStore()
        let now = Date()
        await store.markActive(
            workerID: "Starling", hostname: "starling-runner", runnerVersion: "0.5.498",
            at: now.addingTimeInterval(-600))
        await store.markActive(
            workerID: "Sparrow", hostname: "sparrow-runner", runnerVersion: "0.5.499", at: now)

        let online = await store.activeRunners(withinSeconds: 120, now: now)
        #expect(online.map(\.workerID) == ["Sparrow"])
        let remembered = await store.knownRunnerVersions(rememberSeconds: 3600, now: now)
        #expect(Set(remembered) == ["0.5.498", "0.5.499"])
    }

    /// A runner host's update job runs every 10 minutes and a drain takes up
    /// to 10 more, so a correct runner can be about 25 minutes behind.
    @Test func theSkewGraceCoversAnUpdateJobAndADrain() {
        #expect(ServerHealthAlertConfiguration.default.runnerVersionSkewGraceSeconds >= 25 * 60)
    }
}

// MARK: - The evaluation on the database

@Suite(.serialized) final class UnclaimableJobsEvaluationTests {
    let app: Application

    /// Whole seconds, so a wait read back from the database gives an exact
    /// number of minutes.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    init() async throws {
        app = try await makeTestApp(prefix: "unclaimable-eval")
    }

    // MARK: - Which jobs wait

    @Test func anOldJobThatNoOnlineRunnerMayGradeFiresAndNamesTheAssignment() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_old", minimumRunnerVersion: "0.5.500")
            try await makeAssignment(setupID: setupID, title: "Lab 3")
            try await makeSubmission("unclaim_old_1", setupID: setupID, submittedSecondsAgo: 630)
            await markOnline("Sparrow", version: "0.5.499")

            let evaluation = try await evaluateUnclaimableJobs(on: app, now: now)
            #expect(evaluation.isFiring)
            #expect(evaluation.details["blocked_jobs"] == "1")
            #expect(evaluation.details["blocked_test_setups"] == setupID)
            #expect(evaluation.details["online_runners"] == "Sparrow")
            #expect(evaluation.details["assignments"] == "Lab 3")
            #expect(evaluation.summary.contains("1 submission for Lab 3"), "\(evaluation.summary)")
            #expect(evaluation.summary.contains("oldest 10 min"), "\(evaluation.summary)")
            #expect(evaluation.summary.contains("0.5.500"), "the reason names the minimum: \(evaluation.summary)")
        }
    }

    /// A runner claims a job it can grade within seconds, so a job younger
    /// than the minimum wait is not yet a sign of a fault.
    @Test func aJobYoungerThanTheMinimumWaitIsNotCounted() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_young", minimumRunnerVersion: "0.5.500")
            try await makeAssignment(setupID: setupID, title: "Lab 4")
            try await makeSubmission(
                "unclaim_young_1", setupID: setupID,
                submittedSecondsAgo: unclaimableJobsMinimumWaitSeconds - 60)
            await markOnline("Sparrow", version: "0.5.499")

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    /// A retest puts an old submission back in the queue. Its wait starts at
    /// the retest, not at the first submission.
    @Test func aRecentRetestOfAnOldSubmissionIsNotCounted() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_retest_new", minimumRunnerVersion: "0.5.500")
            try await makeAssignment(setupID: setupID, title: "Lab 5")
            try await makeSubmission(
                "unclaim_retest_new_1", setupID: setupID, submittedSecondsAgo: 3600, retestedSecondsAgo: 60)
            await markOnline("Sparrow", version: "0.5.499")

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    @Test func theOldestWaitOfARetestCountsFromTheRetest() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_retest_old", minimumRunnerVersion: "0.5.500")
            try await makeAssignment(setupID: setupID, title: "Lab 6")
            try await makeSubmission(
                "unclaim_retest_old_1", setupID: setupID, submittedSecondsAgo: 3600, retestedSecondsAgo: 930)
            await markOnline("Sparrow", version: "0.5.499")

            let evaluation = try await evaluateUnclaimableJobs(on: app, now: now)
            #expect(evaluation.isFiring)
            #expect(evaluation.summary.contains("oldest 15 min"), "\(evaluation.summary)")
        }
    }

    @Test(arguments: [SubmissionStatus.assigned, .running, .complete, .failed, .arena])
    func aJobThatIsNotPendingIsNotCounted(status: SubmissionStatus) async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_status", minimumRunnerVersion: "0.5.500")
            try await makeAssignment(setupID: setupID, title: "Lab 7")
            try await makeSubmission(
                "unclaim_status_1", setupID: setupID, submittedSecondsAgo: 3600, status: status)
            await markOnline("Sparrow", version: "0.5.499")

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    /// The runner-offline rule covers a fleet with no runner up.
    @Test func noOnlineRunnerKeepsItQuietEvenWithABlockedJob() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_offline", minimumRunnerVersion: "0.5.500")
            try await makeSubmission("unclaim_offline_1", setupID: setupID, submittedSecondsAgo: 3600)
            await app.workerActivityStore.markActive(
                workerID: "Sparrow", hostname: "sparrow.local", runnerVersion: "0.5.499",
                at: now.addingTimeInterval(-(unclaimableJobsOnlineRunnerSeconds + 60)))

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    @Test func anOnlineRunnerThatMayGradeTheJobKeepsItQuiet() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_ok", minimumRunnerVersion: "0.5.500")
            try await makeAssignment(setupID: setupID, title: "Lab 8")
            try await makeSubmission("unclaim_ok_1", setupID: setupID, submittedSecondsAgo: 3600)
            await markOnline("Sparrow", version: "0.5.499")
            await markOnline("Chickadee", version: "0.5.500")

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    // MARK: - Naming and grouping

    /// A setup that no assignment row names is listed by its ID.
    @Test func aSetupWithNoAssignmentIsNamedByItsID() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_orphan", minimumRunnerVersion: "0.5.500")
            try await makeSubmission("unclaim_orphan_1", setupID: setupID, submittedSecondsAgo: 630)
            await markOnline("Sparrow", version: "0.5.499")

            let evaluation = try await evaluateUnclaimableJobs(on: app, now: now)
            #expect(evaluation.isFiring)
            #expect(evaluation.details["assignments"] == "test setup \(setupID)")
            #expect(evaluation.summary.contains("test setup \(setupID)"), "\(evaluation.summary)")
        }
    }

    /// The jobs of one setup are one group: the count is the jobs, and the
    /// setup is listed once. Blocked setups are listed in ID order.
    @Test func jobsAreGroupedBySetupAndSetupsAreListedInOrder() async throws {
        try await withApp(app) { app in
            let second = try await makeSetup("unclaim_group_b", minimumRunnerVersion: "0.5.500")
            let first = try await makeSetup("unclaim_group_a", minimumRunnerVersion: "0.5.500")
            try await makeSubmission("unclaim_group_b1", setupID: second, submittedSecondsAgo: 630)
            try await makeSubmission("unclaim_group_b2", setupID: second, submittedSecondsAgo: 700)
            try await makeSubmission("unclaim_group_a1", setupID: first, submittedSecondsAgo: 1230)
            await markOnline("Sparrow", version: "0.5.499")

            let evaluation = try await evaluateUnclaimableJobs(on: app, now: now)
            #expect(evaluation.details["blocked_jobs"] == "3")
            #expect(evaluation.details["blocked_test_setups"] == "\(first),\(second)")
            #expect(evaluation.summary.contains("3 submissions"), "\(evaluation.summary)")
            #expect(evaluation.summary.contains("oldest 20 min"), "\(evaluation.summary)")
        }
    }

    /// A setup whose manifest does not decode cannot be judged, so the rule
    /// leaves it out rather than fire on it.
    @Test func aSetupWithAnUnreadableManifestIsLeftOut() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_bad_manifest", manifest: "not a manifest")
            try await makeAssignment(setupID: setupID, title: "Lab 9")
            try await makeSubmission("unclaim_bad_manifest_1", setupID: setupID, submittedSecondsAgo: 3600)
            await markOnline("Sparrow", version: "0.5.499")

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    // MARK: - Profiles and requirements

    /// The rule reads each online runner's stored profile and the
    /// assignment's requirement, and decides with both.
    @Test func aRequirementNoOnlineRunnerProfileMeetsFiresWithTheReason() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_req_block")
            let assignment = try await makeAssignment(setupID: setupID, title: "Needs Pandas")
            try await requirePandas(assignmentID: assignment.requireID())
            try await makeSubmission("unclaim_req_block_1", setupID: setupID, submittedSecondsAgo: 630)
            await markOnline("Sparrow", version: "0.5.499")
            try await saveProfile("Sparrow", capabilities: ["numpy"])

            let evaluation = try await evaluateUnclaimableJobs(on: app, now: now)
            #expect(evaluation.isFiring)
            #expect(evaluation.details["reasons"]?.contains("pandas") == true, "\(evaluation.details)")
        }
    }

    @Test func aRunnerWhoseStoredProfileMeetsTheRequirementKeepsItQuiet() async throws {
        try await withApp(app) { app in
            let setupID = try await makeSetup("unclaim_req_ok")
            let assignment = try await makeAssignment(setupID: setupID, title: "Needs Pandas")
            try await requirePandas(assignmentID: assignment.requireID())
            try await makeSubmission("unclaim_req_ok_1", setupID: setupID, submittedSecondsAgo: 630)
            await markOnline("Sparrow", version: "0.5.499")
            try await saveProfile("Sparrow", capabilities: ["numpy"])
            await markOnline("Starling", version: "0.5.499")
            try await saveProfile("Starling", capabilities: ["pandas"])

            #expect(!(try await evaluateUnclaimableJobs(on: app, now: now)).isFiring)
        }
    }

    // MARK: - Fixtures

    private func markOnline(_ workerID: String, version: String) async {
        await app.workerActivityStore.markActive(
            workerID: workerID, hostname: "\(workerID.lowercased()).local", runnerVersion: version, at: now)
    }

    private func makeSetup(
        _ id: String, minimumRunnerVersion: String? = nil, manifest: String? = nil
    ) async throws -> String {
        let course = APICourse(code: "UNC_\(id)", name: "Unclaimable", enrollmentMode: .closed)
        try await course.save(on: app.db)
        var fields =
            #""schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"#
            + #""testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10"#
        if let minimumRunnerVersion {
            fields += #","minimumRunnerVersion":"\#(minimumRunnerVersion)""#
        }
        let setup = try await makeTestSetup(
            on: app, id: id, courseID: try course.requireID(),
            manifest: manifest ?? "{\(fields)}", withNotebook: false, withZip: false)
        return try setup.requireID()
    }

    @discardableResult
    private func makeAssignment(setupID: String, title: String) async throws -> APIAssignment {
        let courseID = try #require(try await APITestSetup.find(setupID, on: app.db)?.courseID)
        let assignment = APIAssignment(testSetupID: setupID, title: title, isOpen: true, courseID: courseID)
        try await assignment.save(on: app.db)
        return assignment
    }

    private func makeSubmission(
        _ id: String, setupID: String, submittedSecondsAgo: TimeInterval,
        retestedSecondsAgo: TimeInterval? = nil, status: SubmissionStatus = .pending
    ) async throws {
        let submission = APISubmission(
            id: id, testSetupID: setupID, zipPath: "/tmp/\(id).zip", attemptNumber: 1,
            status: status.rawValue, filename: "submission.zip", userID: nil, kind: APISubmission.Kind.student)
        try await submission.save(on: app.db)
        // `submittedAt` is set on create, so the past time is written after.
        submission.submittedAt = now.addingTimeInterval(-submittedSecondsAgo)
        submission.retestedAt = retestedSecondsAgo.map { now.addingTimeInterval(-$0) }
        try await submission.save(on: app.db)
    }

    private func requirePandas(assignmentID: UUID) async throws {
        let spec = AssignmentRequirementSpec(
            requiredPlatform: nil, requiredArchitecture: nil, requiredLanguages: [],
            requiredCapabilities: [RunnerCapability(name: "pandas")])
        try await AssignmentRequirement(assignmentID: assignmentID, specification: spec).save(on: app.db)
    }

    private func saveProfile(_ runnerID: String, capabilities: [String]) async throws {
        let profile = RunnerProfile(
            runnerID: runnerID,
            profile: RunnerCapabilityProfile(
                platform: "linux", architecture: "x86_64",
                languageVersions: [LanguageVersion(language: "python", version: "3.12.0")],
                capabilities: capabilities.map { RunnerCapability(name: $0) }),
            profileHash: nil, lastRegisteredAt: now, lastSeenAt: now)
        try await profile.save(on: app.db)
    }
}
