import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

/// Pure bucket-math tests for the admin card sparklines (no app fixture).
@Suite struct MetricsCardAccumulatorTests {
    @Test func windowDefinitionsCoverExpectedSpans() {
        #expect(MetricsCardWindow.day.bucketCount == 24)
        #expect(MetricsCardWindow.week.bucketCount == 28)
        #expect(MetricsCardWindow.month.bucketCount == 30)
        #expect(MetricsCardWindow.day.totalSeconds == 86_400)
        #expect(MetricsCardWindow.week.totalSeconds == 7 * 86_400)
        #expect(MetricsCardWindow.month.totalSeconds == 30 * 86_400)
    }

    @Test func perBucketMaxQueueDepthCarriesDepthAcrossBuckets() {
        let windowStart = Date(timeIntervalSince1970: 0)
        let window = BucketWindow(windowStart: windowStart, bucketSeconds: 60, bucketCount: 4)
        // Two submissions arrive in bucket 0; one is assigned in bucket 2.
        let timeline = QueueDepthTimeline(
            initialDepth: 0,
            events: [
                QueueDepthEvent(date: Date(timeIntervalSince1970: 10), delta: 1),
                QueueDepthEvent(date: Date(timeIntervalSince1970: 20), delta: 1),
                QueueDepthEvent(date: Date(timeIntervalSince1970: 130), delta: -1),
            ]
        )
        let series = MetricsCardAccumulators.perBucketMaxQueueDepth(timeline: timeline, window: window)
        // Bucket 0 peaks at 2; bucket 1 carries the depth of 2 with no
        // events; bucket 2 starts at 2 before draining to 1; bucket 3
        // carries the remaining 1.
        #expect(series == [2, 2, 2, 1])
    }

    @Test func perBucketMaxQueueDepthFoldsPreWindowEventsIntoCarriedDepth() {
        let window = BucketWindow(
            windowStart: Date(timeIntervalSince1970: 100), bucketSeconds: 50, bucketCount: 2)
        // Timeline opens earlier than the charted window: the +1/+1/−1 before
        // 100 must fold into the depth carried into bucket 0.
        let timeline = QueueDepthTimeline(
            initialDepth: 1,
            events: [
                QueueDepthEvent(date: Date(timeIntervalSince1970: 10), delta: 1),
                QueueDepthEvent(date: Date(timeIntervalSince1970: 20), delta: 1),
                QueueDepthEvent(date: Date(timeIntervalSince1970: 30), delta: -1),
                QueueDepthEvent(date: Date(timeIntervalSince1970: 120), delta: 1),
            ]
        )
        let series = MetricsCardAccumulators.perBucketMaxQueueDepth(timeline: timeline, window: window)
        #expect(series == [3, 3])
        // The whole-timeline peak agrees with the bucket maxima.
        #expect(MetricsCardAccumulators.maxQueueDepth(timeline: timeline) == 3)
    }

    @Test func perBucketMaxQueueDepthClampsTrailingEventsIntoLastBucket() {
        let windowStart = Date(timeIntervalSince1970: 0)
        let window = BucketWindow(windowStart: windowStart, bucketSeconds: 60, bucketCount: 2)
        // An event landing exactly on the window's end boundary still counts
        // (parity with maxQueueDepthSince, which includes events at `now`).
        let timeline = QueueDepthTimeline(
            initialDepth: 0,
            events: [QueueDepthEvent(date: Date(timeIntervalSince1970: 120), delta: 1)]
        )
        let series = MetricsCardAccumulators.perBucketMaxQueueDepth(timeline: timeline, window: window)
        #expect(series == [0, 1])
    }

    @Test func perBucketMaxQueueDepthNeverGoesNegative() {
        let windowStart = Date(timeIntervalSince1970: 0)
        let window = BucketWindow(windowStart: windowStart, bucketSeconds: 60, bucketCount: 1)
        let timeline = QueueDepthTimeline(
            initialDepth: 0,
            events: [
                QueueDepthEvent(date: Date(timeIntervalSince1970: 10), delta: -1),
                QueueDepthEvent(date: Date(timeIntervalSince1970: 20), delta: 1),
            ]
        )
        let series = MetricsCardAccumulators.perBucketMaxQueueDepth(timeline: timeline, window: window)
        #expect(series == [1])
    }
}

/// Endpoint tests for `GET /admin/metrics/cards`.
@Suite(.serialized) final class MetricsCardSeriesRouteTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cards")
    }

    /// The load series sums concurrent runners' busy slots and capacity within
    /// a bucket, and reports the window's peak pair.  Exercises the Swift
    /// aggregation on SQLite locally; `api-tests-postgres` runs the same
    /// assertions through the Postgres SQL path.
    @Test func runnerLoadPointsSumConcurrentRunners() async throws {
        try await withApp(app) { _ in
            let now = Date()
            // Buckets are epoch-aligned (floor(epochSeconds / 300)), so two raw
            // `now`-relative offsets 10 s apart share a bucket only when `now`
            // doesn't place a 300 s boundary between them — a ~3 % wall-clock
            // flake. Anchor to the start of the bucket containing `now` and place
            // each snapshot safely inside its target bucket instead.
            let bucket = 300.0
            let anchor = Date(
                timeIntervalSince1970: (now.timeIntervalSince1970 / bucket).rounded(.down) * bucket)
            // Two runners in the SAME bucket: r1 busy 2/4, r2 busy 1/4 → summed
            // 3/8. Both sit well inside [anchor − 2·bucket, anchor − bucket).
            try await saveSnapshot(
                runner: "r1", at: anchor.addingTimeInterval(-2 * bucket + 60), active: 2, max: 4)
            try await saveSnapshot(
                runner: "r2", at: anchor.addingTimeInterval(-2 * bucket + 120), active: 1, max: 4)
            // A later, quieter bucket: only r1, busy 0/4, inside [anchor − bucket, anchor).
            try await saveSnapshot(
                runner: "r1", at: anchor.addingTimeInterval(-bucket + 60), active: 0, max: 4)

            let points = try await app.diagnostics.runnerLoadPoints(
                since: now.addingTimeInterval(-3600), on: app.db)

            // Two distinct 5-minute buckets.
            #expect(points.count == 2)
            let busy = try #require(points.max(by: { $0.totalActive < $1.totalActive }))
            #expect(busy.totalActive == 3)
            #expect(busy.totalMax == 8)
        }
    }

    /// Per-display-bucket runner summaries: per-snapshot utilization is
    /// averaged and peaked within each bucket.  Exercises the Swift aggregation
    /// on SQLite locally; `api-tests-postgres` runs the same assertions through
    /// the Postgres SQL path, pinning the two paths to identical output.
    @Test func runnerTimeseriesSummariesAggregatePerBucket() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let window = BucketWindow.resolve(
                hours: 1, bucketMinutes: 30, defaultHours: 24, now: now
            ).window

            // Bucket 0 ([-60m, -30m)): r1 at 2/4 (50%) then 4/4 (100%).
            try await saveSnapshot(runner: "r1", at: now.addingTimeInterval(-3000), active: 2, max: 4)
            try await saveSnapshot(runner: "r1", at: now.addingTimeInterval(-2700), active: 4, max: 4)
            // Bucket 1 ([-30m, now)): r2 at 1/2 (50%).
            try await saveSnapshot(runner: "r2", at: now.addingTimeInterval(-1200), active: 1, max: 2)

            let summaries = try await app.diagnostics.runnerTimeseriesSummaries(
                window: window, on: app.db)

            #expect(summaries.count == 2)
            #expect(summaries[0].avgUtilizationPercent == 75)  // (50 + 100) / 2
            #expect(summaries[0].maxUtilizationPercent == 100)
            #expect(summaries[0].avgActiveRunners == 1)
            #expect(summaries[1].avgUtilizationPercent == 50)
            #expect(summaries[1].maxUtilizationPercent == 50)
        }
    }

    /// The instructor card series buckets student submissions per window and
    /// reports distinct active students / assignments.  Runs on SQLite locally
    /// and the Postgres path in CI.
    @Test func instructorCardSeriesBucketsSubmissions() async throws {
        try await withApp(app) { _ in
            let now = Date()
            let s1 = try await makeSetup(id: "ics_s1").requireID()
            let s2 = try await makeSetup(id: "ics_s2").requireID()
            let studentA = try await makeStudent(username: "ics_a")
            let studentB = try await makeStudent(username: "ics_b")
            let studentC = try await makeStudent(username: "ics_c")

            try await saveStudentSubmission(
                id: "ics_1", setupID: s1, userID: studentA, at: now.addingTimeInterval(-2 * 3600))
            try await saveStudentSubmission(
                id: "ics_2", setupID: s2, userID: studentA, at: now.addingTimeInterval(-3 * 3600))
            try await saveStudentSubmission(
                id: "ics_3", setupID: s1, userID: studentB, at: now.addingTimeInterval(-1 * 3600))
            // Outside the 30-day window — excluded everywhere.
            try await saveStudentSubmission(
                id: "ics_old", setupID: s1, userID: studentA, at: now.addingTimeInterval(-40 * 86400))
            // Enrolled-student filter excludes this one (student C not passed in).
            try await saveStudentSubmission(
                id: "ics_other", setupID: s1, userID: studentC, at: now.addingTimeInterval(-30 * 60))

            // Browser errors: raw diagnostic events per bucket (not deduped).
            try await saveDiagnostic(
                userID: studentA, setupID: s1, kind: "preflight_fail", at: now.addingTimeInterval(-2 * 3600))
            try await saveDiagnostic(
                userID: studentA, setupID: s1, kind: "watchdog_timeout", at: now.addingTimeInterval(-90 * 60))
            try await saveDiagnostic(
                userID: studentB, setupID: s2, kind: "preflight_fail", at: now.addingTimeInterval(-10 * 3600))
            // Excluded: out of the 30-day window.
            try await saveDiagnostic(
                userID: studentA, setupID: s1, kind: "watchdog_timeout", at: now.addingTimeInterval(-40 * 86400))
            // Excluded: null test_setup_id (unattributable to the course).
            try await saveDiagnostic(
                userID: studentA, setupID: nil, kind: "watchdog_timeout", at: now.addingTimeInterval(-60 * 60))
            // Excluded: non-enrolled student.
            try await saveDiagnostic(
                userID: studentC, setupID: s1, kind: "preflight_fail", at: now.addingTimeInterval(-60 * 60))
            // Excluded: not an error kind.
            try await saveDiagnostic(userID: studentA, setupID: s1, kind: "info", at: now.addingTimeInterval(-60 * 60))

            let response = try await app.diagnostics.instructorCardSeries(
                setupIDs: [s1, s2], studentIDs: [studentA, studentB], on: app.db, now: now)

            let day = try #require(response.windows.first { $0.window == "24h" })
            #expect(day.submissions.headline == 3)
            #expect(day.activeStudents.headline == 2)
            #expect(day.activeAssignments.headline == 2)
            #expect(day.submissions.series.compactMap { $0 }.reduce(0, +) == 3)
            // 3 in-window error events (2 from A + 1 from B); the others are filtered.
            #expect(day.browserErrors.headline == 3)
            #expect(day.browserErrors.series.compactMap { $0 }.reduce(0, +) == 3)

            // The 30-day window also excludes the 40-day-old rows and the
            // non-enrolled student.
            let month = try #require(response.windows.first { $0.window == "1m" })
            #expect(month.submissions.headline == 3)
            #expect(month.browserErrors.headline == 3)
        }
    }

    private func saveDiagnostic(userID: UUID, setupID: String?, kind: String, at: Date) async throws {
        let diagnostic = APIClientDiagnostic(
            userID: userID, testSetupID: setupID, kind: kind, failedChecks: nil, userAgent: "TestUA")
        try await diagnostic.save(on: app.db)
        diagnostic.createdAt = at
        try await diagnostic.update(on: app.db)
    }

    private func makeStudent(username: String) async throws -> UUID {
        let user = APIUser(username: username, passwordHash: "x", role: "student")
        try await user.save(on: app.db)
        return try user.requireID()
    }

    private func saveStudentSubmission(id: String, setupID: String, userID: UUID, at: Date) async throws {
        let submission = APISubmission(
            id: id, testSetupID: setupID, zipPath: "/tmp/\(id).zip",
            attemptNumber: 1, status: "completed", userID: userID,
            kind: APISubmission.Kind.student)
        try await submission.save(on: app.db)
        submission.submittedAt = at
        try await submission.update(on: app.db)
    }

    private func saveSnapshot(runner: String, at: Date, active: Int, max: Int) async throws {
        let snapshot = RunnerSnapshot(
            runnerID: runner, recordedAt: at, activeJobs: active, maxJobs: max,
            availableCapacity: Swift.max(0, max - active), hostname: runner, runnerVersion: "x",
            lastPollAt: at, lastHeartbeatAt: at, serverAssignedJobCountSinceStart: 0)
        try await snapshot.save(on: app.db)
    }

    /// The Max Load headline must be scoped to each card's own window.  The
    /// load points are fetched once for the longest (30-day) window and reused
    /// across windows, so a peak that lands outside the 24h window must not
    /// leak into the 24h headline (regression: every window showed the 30-day
    /// peak, e.g. a stale 13/13).
    @Test func loadHeadlineScopedToEachWindow() async throws {
        try await withApp(app) { _ in
            let now = Date()
            // A saturated peak (13/13) two days ago: inside 7d / 30d, outside 24h.
            try await saveSnapshot(
                runner: "lhs_old", at: now.addingTimeInterval(-2 * 86400), active: 13, max: 13)
            // A quieter, recent sample (2/13) ten minutes ago: inside every window.
            try await saveSnapshot(
                runner: "lhs_recent", at: now.addingTimeInterval(-600), active: 2, max: 13)

            let response = try await app.diagnostics.metricsCardSeries(on: app.db, now: now)

            let day = try #require(response.windows.first { $0.window == "24h" })
            // 24h sees only the recent 2/13 — not the two-day-old saturation.
            #expect(day.load.activeJobs == 2)
            #expect(day.load.capacity == 13)

            let week = try #require(response.windows.first { $0.window == "1w" })
            // 7d (and 30d) include the saturated peak.
            #expect(week.load.activeJobs == 13)
            #expect(week.load.capacity == 13)

            let month = try #require(response.windows.first { $0.window == "1m" })
            #expect(month.load.activeJobs == 13)
            #expect(month.load.capacity == 13)
        }
    }

    @Test func cardsEndpointRequiresAuthentication() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(
                .GET, "/admin/metrics/cards",
                afterResponse: { response in
                    #expect(response.status == .seeOther)
                })
        }
    }

    @Test func cardsEndpointReturnsAllWindowsWithSeededData() async throws {
        try await withApp(app) { _ in
            let setup = try await makeSetup(id: "setup_cards")
            // One completed job 10s ago…
            let submission = APISubmission(
                id: "sub_cards_done",
                testSetupID: try setup.requireID(),
                zipPath: "/tmp/sub_cards_done.zip",
                attemptNumber: 1,
                status: "completed",
                kind: APISubmission.Kind.student
            )
            try await submission.save(on: app.db)
            // submittedAt is a create-timestamp; backdate it post-save.
            submission.submittedAt = Date().addingTimeInterval(-20)
            submission.assignedAt = Date().addingTimeInterval(-15)
            try await submission.update(on: app.db)

            let metric = JobExecutionMetric(
                submissionID: "sub_cards_done",
                jobID: "sub_cards_done",
                testSetupID: try setup.requireID(),
                courseID: nil,
                assignmentID: nil,
                userID: nil,
                runnerID: "runner-cards",
                kind: APISubmission.Kind.student,
                attemptNumber: 1,
                enqueuedAt: Date().addingTimeInterval(-20)
            )
            metric.completedAt = Date().addingTimeInterval(-10)
            metric.queueWaitMs = 5000
            metric.executionMs = 5000
            metric.finalStatus = JobFinalStatus.passed.rawValue
            try await metric.save(on: app.db)

            // …one still pending (contributes to queue depth)…
            let pending = APISubmission(
                id: "sub_cards_pending",
                testSetupID: try setup.requireID(),
                zipPath: "/tmp/sub_cards_pending.zip",
                attemptNumber: 1,
                status: "pending",
                kind: APISubmission.Kind.student
            )
            try await pending.save(on: app.db)
            pending.submittedAt = Date().addingTimeInterval(-5)
            try await pending.update(on: app.db)

            // …and one runner load sample.
            let snapshot = RunnerSnapshot(
                runnerID: "runner-cards",
                recordedAt: Date().addingTimeInterval(-300),
                activeJobs: 1,
                maxJobs: 4,
                availableCapacity: 3,
                hostname: "host-cards",
                runnerVersion: "runner/2.0",
                lastPollAt: Date().addingTimeInterval(-300),
                lastHeartbeatAt: Date().addingTimeInterval(-300),
                serverAssignedJobCountSinceStart: 1
            )
            try await snapshot.save(on: app.db)

            let cookie = try await loginUser(
                username: "admin-cards",
                password: "password123",
                role: "admin",
                on: app
            )

            try await app.asyncTest(
                .GET, "/admin/metrics/cards",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { response in
                    #expect(response.status == .ok)
                    let payload = try response.content.decode(MetricsCardSeriesResponse.self)
                    #expect(payload.windows.map(\.window) == ["24h", "1w", "1m"])
                    #expect(payload.windows.map(\.label) == ["24h", "7d", "30d"])

                    let day = try #require(payload.windows.first)
                    #expect(day.maxQueueDepth.series.count == 24)
                    #expect(day.bucketLabels.count == 24)
                    #expect(payload.windows[1].maxQueueDepth.series.count == 28)
                    #expect(payload.windows[2].maxQueueDepth.series.count == 30)

                    // The completed job shows up in every window's totals.
                    for window in payload.windows {
                        #expect(window.jobsProcessed.headline == 1)
                        #expect(window.queueWaitP95Ms.headline == 5000)
                        #expect(window.executionP95Ms.headline == 5000)
                        #expect(window.load.capacity == 4)
                        #expect(window.load.activeJobs == 1)
                    }
                    // The pending submission keeps the queue depth at >= 1.
                    let queueHeadline = try #require(day.maxQueueDepth.headline)
                    #expect(queueHeadline >= 1)
                    // Activity lands in the trailing buckets.
                    #expect(day.jobsProcessed.series.last == 1)
                })
        }
    }

    private func makeSetup(id: String) async throws -> APITestSetup {
        let course = APICourse(code: "CARDS_\(id)", name: "Card Series", enrollmentMode: .closed)
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
}
