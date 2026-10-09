// APIServer/Routes/Web/AdminRoutes+Runners.swift
//
// Admin runner / worker dashboard routes. The row and timing helpers they
// share with the admin-diagnostics MCP tools are in Services/RunnerFleetRows.swift.
// All routes are registered in AdminRoutes.boot().

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

extension AdminRoutes {
    // MARK: - GET /admin/runners

    @Sendable
    /// Two representations, one query: `?fragment=rows` renders
    /// `_worker-rows.leaf` — the SAME partial the dashboard renders, so the
    /// poll cannot drift from the page — and anything else keeps the JSON
    /// array unchanged (the runner-detail page's poll reads it).
    func runners(req: Request) async throws -> Response {
        let rows = try await makeWorkerRows(req: req)
        guard req.query[String.self, at: "fragment"] == "rows" else {
            return try await rows.encodeResponse(for: req)
        }
        return try await req.view.render(
            "_worker-rows", WorkerRowsFragmentContext(workers: rows.map(AdminRunnerRow.init))
        )
        .encodePollFragment(for: req)
    }

    // MARK: - GET /admin/runners/:runnerID

    @Sendable
    func runnerDetail(req: Request) async throws -> View {
        guard let runnerID = req.parameters.get("runnerID"), !runnerID.isEmpty else {
            throw Abort(.notFound)
        }

        let worker = try await resolveWorkerRow(req: req, runnerID: runnerID)
        let runnerProfile = try? await req.application.runnerProfiles.profile(for: runnerID, on: req.db)

        let snapshots = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .descending)
            .limit(50)
            .all()

        let recentJobs = try await JobExecutionMetric.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$completedAt, .descending)
            .limit(50)
            .all()

        let usersByID = try await fetchUsers(req: req, jobs: recentJobs)
        // A deployment-wide list that belongs to no course: staff anywhere wear
        // the staff ring, as on the account page (#1758).
        let staffIDs = try await AvatarStore.courseStaff(among: Array(usersByID.keys), on: req.db)
        let firstSeenAt = try await fetchFirstSeenAt(req: req, runnerID: runnerID)
        let statusCounts = countStatuses(in: recentJobs)
        let snapshotRows = snapshots.map(snapshotRow(for:))
        let limitBySetupID = await timeLimits(for: recentJobs, on: req.db)
        var jobRows: [AdminRunnerJobRow] = []
        for metric in recentJobs {
            jobRows.append(
                try await jobRow(
                    for: metric, usersByID: usersByID, staffIDs: staffIDs, limitBySetupID: limitBySetupID,
                    on: req.db))
        }
        let chart = Self.utilizationChart(snapshots: snapshots)
        let summary = makeRunnerSummary(worker: worker, recentJobs: recentJobs, statusCounts: statusCounts)
        let tags = makeRunnerTags(profile: runnerProfile)

        return try await req.view.render(
            "admin-runner",
            AdminRunnerDetailContext(
                currentUser: req.currentUserContext,
                runner: worker,
                tags: tags,
                summary: summary,
                recentJobs: jobRows,
                snapshots: snapshotRows,
                firstSeenAt: firstSeenAt,
                chartBars: chart.bars,
                chartLabels: chart.labels,
                offlineForText: Self.offlineDuration(of: worker)
            ))
    }

    // MARK: - runnerDetail helpers

    private func resolveWorkerRow(req: Request, runnerID: String) async throws -> AdminWorkerRow {
        let workerRows = try await makeWorkerRows(req: req)
        if let found = workerRows.first(where: { $0.workerID == runnerID }) {
            return found
        }
        // Runner was pruned from the in-memory store (offline >60 min).
        // Reconstruct a minimal row from the most recent DB snapshot so
        // the detail page can still render historical data instead of 404.
        guard
            let latestSnapshot = try await RunnerSnapshot.query(on: req.db)
                .filter(\.$runnerID == runnerID)
                .sort(\.$recordedAt, .descending)
                .first()
        else {
            throw Abort(.notFound)
        }
        let processedCount = try await APISubmission.query(on: req.db)
            .filter(\.$workerID == runnerID)
            .filter(\.$status ~~ [SubmissionStatus.complete.rawValue, SubmissionStatus.failed.rawValue])
            .count()
        let avgData = try? await req.application.diagnostics.rollingAverages(
            for: [runnerID], sampleSize: 50, on: req.db
        )
        let avg = avgData?[runnerID]
        return AdminWorkerRow(
            workerID: runnerID,
            hostname: latestSnapshot.hostname ?? "",
            runnerVersion: latestSnapshot.runnerVersion ?? "",
            maxConcurrentJobs: latestSnapshot.maxJobs,
            lastActive: iso8601String(latestSnapshot.recordedAt),
            assignedJobs: 0,
            jobsProcessed: processedCount,
            avgExecutionMs: avg?.avgExecutionMs,
            avgQueueWaitMs: avg?.avgQueueWaitMs,
            avgExecutionFormatted: avg?.avgExecutionMs.map(formatMs),
            avgQueueWaitFormatted: avg?.avgQueueWaitMs.map(formatMs),
            isOffline: RunnerStaleness.isOffline(lastActive: latestSnapshot.recordedAt)
        )
    }

    private func fetchUsers(req: Request, jobs: [JobExecutionMetric]) async throws -> [UUID: APIUser] {
        let userIDs = Array(Set(jobs.compactMap { $0.userID }))
        let users =
            userIDs.isEmpty
            ? []
            : try await APIUser.query(on: req.db)
                .filter(\.$id ~~ userIDs)
                .all()
        return Dictionary(
            users.compactMap { user in user.id.map { ($0, user) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// The per-test time limit of each setup a timed-out job ran against, for the
    /// "hit the 10s limit" note. A setup whose manifest will not decode is left
    /// out: the note is a courtesy and must not fail the page.
    private func timeLimits(for jobs: [JobExecutionMetric], on db: Database) async -> [String: Int] {
        let setupIDs = Set(jobs.filter { $0.finalStatus == "timeout" }.map(\.testSetupID))
        guard !setupIDs.isEmpty,
            let setups = try? await APITestSetup.query(on: db).filter(\.$id ~~ Array(setupIDs)).all()
        else { return [:] }
        var limits: [String: Int] = [:]
        for setup in setups {
            guard let id = setup.id,
                let props = decodeManifest(fromJSON: setup.manifest)
            else { continue }
            limits[id] = props.timeLimitSeconds
        }
        return limits
    }

    private func fetchFirstSeenAt(req: Request, runnerID: String) async throws -> String? {
        let firstSnapshot = try await RunnerSnapshot.query(on: req.db)
            .filter(\.$runnerID == runnerID)
            .sort(\.$recordedAt, .ascending)
            .first()
        return firstSnapshot.map { iso8601String($0.recordedAt) }
    }

    private func countStatuses(in jobs: [JobExecutionMetric]) -> [String: Int] {
        var statusCounts: [String: Int] = [:]
        for job in jobs {
            guard let status = job.finalStatus else { continue }
            statusCounts[status, default: 0] += 1
        }
        return statusCounts
    }

    private func snapshotRow(for snapshot: RunnerSnapshot) -> AdminRunnerSnapshotRow {
        let utilizationPercent =
            snapshot.maxJobs > 0
            ? Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded())
            : 0
        return AdminRunnerSnapshotRow(
            recordedAt: iso8601String(snapshot.recordedAt),
            activeJobs: snapshot.activeJobs,
            maxJobs: snapshot.maxJobs,
            activeJobsLabel: "\(snapshot.activeJobs) / \(snapshot.maxJobs)",
            utilizationPercent: utilizationPercent,
            lastPollAt: snapshot.lastPollAt.map(iso8601String)
        )
    }

    private func jobRow(
        for metric: JobExecutionMetric,
        usersByID: [UUID: APIUser],
        staffIDs: Set<UUID>,
        limitBySetupID: [String: Int],
        on db: Database
    ) async throws -> AdminRunnerJobRow {
        let user = metric.userID.flatMap { usersByID[$0] }
        var row = AdminRunnerJobRow(
            submissionID: metric.submissionID,
            assignmentID: metric.assignmentID?.uuidString,
            username: user?.username,
            finalStatus: metric.finalStatus ?? "unknown",
            queueWaitMs: metric.queueWaitMs,
            executionMs: metric.executionMs,
            queueWaitFormatted: metric.queueWaitMs.map(formatMs),
            executionFormatted: metric.executionMs.map(formatMs),
            totalProcessingMs: metric.totalProcessingMs,
            totalProcessingFormatted: metric.totalProcessingMs.map(formatMs),
            workdirPeakBytes: metric.workdirPeakBytes,
            workdirPeakFormatted: metric.workdirPeakBytes.map(formatBytes),
            completedAt: metric.completedAt.map(iso8601String)
        )
        if let user, let userID = user.id {
            row.avatar = try await AvatarStore.rosterAvatar(
                for: user, isStaff: staffIDs.contains(userID), on: db)
            row.hasAvatar = true
        }
        let status = Self.statusPill(for: row.finalStatus)
        row.statusLabel = status.label
        row.statusTier = status.tier
        row.detailsText = Self.jobDetails(row)
        if row.finalStatus == "timeout", let limit = limitBySetupID[metric.testSetupID] {
            row.limitText = "hit the \(limit)s limit"
        }
        return row
    }

    /// The pill for a job's final status: passed is ok, failed and errored are
    /// danger, a timeout is amber, anything else neutral.
    static func statusPill(for status: String) -> (label: String, tier: String) {
        switch status {
        case "passed": return ("Passed", "open")
        case "failed": return ("Failed", "danger")
        case "error": return ("Errored", "danger")
        case "timeout": return ("Timed out", "preview")
        default: return (status.capitalized, "closed")
        }
    }

    /// "wait 1s · run 2s · total 3s · peak disk 12.0 MB · abc123" with the parts a
    /// job did not record left out.
    static func jobDetails(_ row: AdminRunnerJobRow) -> String {
        var parts: [String] = []
        if let wait = row.queueWaitFormatted { parts.append("wait \(wait)") }
        if let run = row.executionFormatted { parts.append("run \(run)") }
        if let total = row.totalProcessingFormatted { parts.append("total \(total)") }
        if let peak = row.workdirPeakFormatted { parts.append("peak disk \(peak)") }
        return parts.joined(separator: " · ")
    }

    /// Snapshots oldest to newest as chart bars, plus the x-axis time labels.
    /// The snapshots arrive newest first, as the query returns them.
    static func utilizationChart(
        snapshots: [RunnerSnapshot],
        timeZone: TimeZone = TimeZone(identifier: "America/Toronto") ?? .current
    ) -> (bars: [AdminRunnerChartBar], labels: [String]) {
        let chronological = Array(snapshots.reversed())
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        clock.timeZone = timeZone
        let bars = chronological.map { snapshot -> AdminRunnerChartBar in
            let percent =
                snapshot.maxJobs > 0
                ? Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded()) : 0
            let state = percent >= 100 ? "full" : (percent == 0 ? "idle" : "busy")
            return AdminRunnerChartBar(
                heightPercent: max(percent, 2),
                state: state,
                title:
                    "\(clock.string(from: snapshot.recordedAt)) · \(snapshot.activeJobs) / \(snapshot.maxJobs) · \(percent)%"
            )
        }
        guard chronological.count > 1 else {
            return (bars, chronological.map { clock.string(from: $0.recordedAt) })
        }
        let wanted = min(4, chronological.count)
        let labels = (0..<wanted).map { slot -> String in
            let index = slot * (chronological.count - 1) / (wanted - 1)
            return clock.string(from: chronological[index].recordedAt)
        }
        return (bars, labels)
    }

    /// How long a runner has been silent, for the offline notice; empty while it
    /// is online.
    static func offlineDuration(of worker: AdminWorkerRow, now: Date = Date()) -> String {
        guard worker.isOffline, let last = iso8601Date(worker.lastActive) else {
            return ""
        }
        return formatMs(Int(now.timeIntervalSince(last) * 1000))
    }

    private func makeRunnerSummary(
        worker: AdminWorkerRow,
        recentJobs: [JobExecutionMetric],
        statusCounts: [String: Int]
    ) -> AdminRunnerSummary {
        let overheadSamples = recentJobs.compactMap { overheadMs(for: $0) }
        let stageBreakdowns = recentJobs.map(stageBreakdown(for:))
        let cacheFlagged = recentJobs.compactMap { $0.testSetupCacheHit }
        let cacheHitRateFormatted: String? = {
            guard !cacheFlagged.isEmpty else { return nil }
            let hits = cacheFlagged.filter { $0 }.count
            let pct = Int((Double(hits) / Double(cacheFlagged.count) * 100).rounded())
            return "\(pct)% (\(hits)/\(cacheFlagged.count))"
        }()

        return AdminRunnerSummary(
            activeJobs: worker.assignedJobs,
            maxJobs: worker.maxConcurrentJobs,
            jobsProcessed: worker.jobsProcessed,
            avgExecutionFormatted: worker.avgExecutionFormatted,
            avgQueueWaitFormatted: worker.avgQueueWaitFormatted,
            avgOverheadFormatted: average(overheadSamples).map(formatMs),
            avgCacheAcquireFormatted: average(stageBreakdowns.compactMap { $0?.cacheAcquireMs }).map(formatMs),
            avgDownloadFormatted: average(stageBreakdowns.compactMap { $0?.downloadMs }).map(formatMs),
            avgPrepFormatted: average(stageBreakdowns.compactMap { $0?.prepMs }).map(formatMs),
            cacheHitRateFormatted: cacheHitRateFormatted,
            passedCount: statusCounts["passed", default: 0],
            failedCount: statusCounts["failed", default: 0],
            errorCount: statusCounts["error", default: 0],
            timeoutCount: statusCounts["timeout", default: 0]
        )
    }

    private func makeRunnerTags(profile: RunnerProfile?) -> [String] {
        guard let profile = profile?.capabilityProfile else { return [] }
        var values: [String] = []
        if !profile.platform.isEmpty {
            values.append(profile.platform)
        }
        if !profile.architecture.isEmpty {
            values.append(profile.architecture)
        }
        values.append(contentsOf: profile.languageVersions.map { "\($0.language) \($0.version)" })
        values.append(contentsOf: profile.capabilities.map(\.name))
        return values
    }
}
