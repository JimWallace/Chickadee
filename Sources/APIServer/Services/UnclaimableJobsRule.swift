// APIServer/Services/UnclaimableJobsRule.swift
//
// The health rule for queued jobs that no online runner can grade. A runner
// updates only once it has drained (cordon and drain), so a runner behind the
// server is normal for a while and is not by itself a fault. What is a fault
// is a job that waits because every runner that is up refuses it: an
// assignment's `minimumRunnerVersion` above every runner, a language no runner
// has, or a capability no runner advertises. The queue rule notices such jobs
// only when they grow old, and does not say why; this one names the reason.

import Core
import Fluent
import Foundation
import Vapor

/// A runner that polled recently, with what it advertises.
struct OnlineRunner: Sendable {
    let workerID: String
    let runnerVersion: String
    let profile: RunnerCapabilityProfile?
}

/// Pending jobs for one test setup, with what grading them needs.
struct WaitingJobGroup: Sendable {
    let testSetupID: String
    let manifest: TestProperties
    let requirements: AssignmentRequirementSpec?
    let jobCount: Int
    let oldestWaitSeconds: TimeInterval
    /// The title of each assignment that uses the setup, joined with " / ",
    /// for the summary. Nil when no assignment row names the setup; the
    /// summary then lists the setup by its ID.
    var assignmentTitle: String?
}

/// How long a job waits before the rule looks at it. A runner claims a job it
/// can grade within seconds, and a runner restarting after an update is gone
/// for about a minute; five minutes keeps both out.
let unclaimableJobsMinimumWaitSeconds: TimeInterval = 300

/// How recently a runner must have polled to count as online. Runners poll at
/// least every 30 seconds, and this matches the admin dashboard's window.
let unclaimableJobsOnlineRunnerSeconds: TimeInterval = 120

/// Fires when a group of waiting jobs has no online runner that may grade it,
/// by the same decision the claim walk makes (`claimCompatibility`). With no
/// runner online it stays quiet: the runner-offline rule covers that.
func decideUnclaimableJobs(groups: [WaitingJobGroup], runners: [OnlineRunner]) -> RuleEvaluation {
    guard !runners.isEmpty else { return .ok }
    var blocked: [(group: WaitingJobGroup, reasons: [String])] = []
    for group in groups {
        let results = runners.map {
            claimCompatibility(
                runnerVersion: $0.runnerVersion, runnerProfile: $0.profile,
                manifest: group.manifest, requirements: group.requirements)
        }
        guard !results.contains(where: \.isCompatible) else { continue }
        var reasons: [String] = []
        for reason in results.flatMap(\.reasons) where !reasons.contains(reason) {
            reasons.append(reason)
        }
        blocked.append((group, reasons))
    }
    guard !blocked.isEmpty else { return .ok }

    let jobCount = blocked.reduce(0) { $0 + $1.group.jobCount }
    let oldestMinutes = Int((blocked.map(\.group.oldestWaitSeconds).max() ?? 0) / 60)
    let reasons = blocked.first?.reasons.joined(separator: "; ") ?? ""
    // A setup no assignment row names is listed by its ID, so every blocked
    // setup appears once and the count after "and N more" is exact.
    let names = blocked.map { $0.group.assignmentTitle ?? "test setup \($0.group.testSetupID)" }
    let jobs = jobCount == 1 ? "1 submission" : "\(jobCount) submissions"
    return RuleEvaluation(
        isFiring: true,
        summary:
            "\(jobs) for \(alertNamedList(names)) wait with no online runner that can grade them "
            + "(oldest \(oldestMinutes) min): \(reasons). Update or add a runner that meets the requirement.",
        details: [
            "blocked_jobs": String(jobCount),
            "blocked_test_setups": blocked.map(\.group.testSetupID).joined(separator: ","),
            "online_runners": runners.map(\.workerID).joined(separator: ","),
            "reasons": reasons,
            "assignments": names.joined(separator: "; "),
        ]
    )
}

/// Collects the waiting jobs and the online runners, then decides.
func evaluateUnclaimableJobs(on application: Application, now: Date) async throws -> RuleEvaluation {
    let active = await application.workerActivityStore.activeRunners(
        withinSeconds: unclaimableJobsOnlineRunnerSeconds, now: now)
    guard !active.isEmpty else { return .ok }
    // One read for every online runner's profile, not one per runner.
    let profiles = try await application.runnerProfiles.profiles(
        for: active.map(\.workerID), on: application.db)
    let runners = active.map { runner in
        OnlineRunner(
            workerID: runner.workerID, runnerVersion: runner.runnerVersion,
            profile: profiles[runner.workerID]?.capabilityProfile)
    }

    let cutoff = now.addingTimeInterval(-unclaimableJobsMinimumWaitSeconds)
    let waiting = try await APISubmission.query(on: application.db)
        .filter(\.$status == SubmissionStatus.pending.rawValue)
        .sort(\.$submittedAt, .ascending)
        .limit(500)
        .all()
        .filter { ($0.retestedAt ?? $0.submittedAt).map { $0 <= cutoff } ?? false }

    let jobsBySetup = Dictionary(grouping: waiting, by: \.testSetupID)
    // One read for every waiting setup, not one per setup on each tick.
    let setupIDs = Array(jobsBySetup.keys)
    let setupsByID: [String: APITestSetup] =
        setupIDs.isEmpty
        ? [:]
        : Dictionary(
            try await APITestSetup.query(on: application.db).filter(\.$id ~~ setupIDs).all()
                .compactMap { setup in setup.id.map { ($0, setup) } },
            uniquingKeysWith: { first, _ in first })
    // One read for the titles too: the summary names the assignments.
    let titlesBySetup: [String: String] =
        setupIDs.isEmpty
        ? [:]
        : Dictionary(
            try await APIAssignment.query(on: application.db).filter(\.$testSetupID ~~ setupIDs).all()
                .map { ($0.testSetupID, $0.title) },
            uniquingKeysWith: { "\($0) / \($1)" })
    var groups: [WaitingJobGroup] = []
    for (testSetupID, jobs) in jobsBySetup {
        guard let first = jobs.first,
            let setup = setupsByID[testSetupID],
            let manifest = decodeManifest(fromJSON: setup.manifest)
        else { continue }
        let requirement = try await application.assignmentRequirements.loadRequirement(
            for: first, on: application.db)
        let oldest = jobs.compactMap { $0.retestedAt ?? $0.submittedAt }.min() ?? now
        groups.append(
            WaitingJobGroup(
                testSetupID: testSetupID, manifest: manifest,
                requirements: requirement.requirement?.requirementSpec,
                jobCount: jobs.count, oldestWaitSeconds: now.timeIntervalSince(oldest),
                assignmentTitle: titlesBySetup[testSetupID]))
    }
    return decideUnclaimableJobs(groups: groups.sorted { $0.testSetupID < $1.testSetupID }, runners: runners)
}
