// Sources/APIServer/Diagnostics/InstructorCardSeries.swift
//
// Builder for `GET /instructor/metrics/cards`: headline + sparkline series for
// the instructor dashboard's diagnostic cards, scoped to the active course.
// Mirrors the admin card series (one response carries every selectable window
// so the client cycles 24h / 7d / 30d without extra round-trips), but the
// metrics are course-facing: student submissions, active students, and active
// assignments over time.
//
// Data limiting: the whole series is derived from a *single* fetch of the
// longest (30-day) window's student submissions, projected to the three
// columns the buckets need — never the full submissions table.  Unlike the
// timer-driven RunnerSnapshot table, submissions are activity-bound, so this
// stays proportional to real course activity.

import Core
import Fluent
import Foundation
import Vapor

/// All instructor card series for one window.
struct InstructorCardWindowSeries: Content, Sendable {
    let window: String
    let label: String
    let bucketLabels: [String]
    let submissions: MetricsCardSeries
    let activeStudents: MetricsCardSeries
    let activeAssignments: MetricsCardSeries
    let browserErrors: MetricsCardSeries
}

/// Payload of `GET /instructor/metrics/cards`.
struct InstructorCardSeriesResponse: Content, Sendable {
    let generatedAt: Date
    let windows: [InstructorCardWindowSeries]
}

extension OperationalDiagnosticsService {

    /// A single projected student submission used to build the card buckets.
    struct InstructorSubmissionPoint: Sendable {
        let submittedAt: Date
        let userID: UUID
        let testSetupID: String
    }

    /// Builds the per-card sparkline payload for one course.  All three windows
    /// are derived from one trailing fetch of the longest (30-day) window, so
    /// the dashboard's poll costs a single query regardless of how many windows
    /// the cards cycle through.
    func instructorCardSeries(
        setupIDs: [String],
        studentIDs: Set<UUID>,
        on db: Database,
        now: Date = Date()
    ) async throws -> InstructorCardSeriesResponse {
        let longestWindow = MetricsCardWindow.allCases.max { $0.totalSeconds < $1.totalSeconds } ?? .month
        let outerStart = now.addingTimeInterval(-longestWindow.totalSeconds)

        let points = try await instructorSubmissionPoints(
            setupIDs: setupIDs, studentIDs: studentIDs, since: outerStart, on: db)
        let browserErrorDates = try await instructorBrowserErrorDates(
            setupIDs: setupIDs, studentIDs: studentIDs, since: outerStart, on: db)

        let windows = MetricsCardWindow.allCases.map { window in
            buildInstructorWindow(
                window: window, now: now, points: points, browserErrorDates: browserErrorDates)
        }
        return InstructorCardSeriesResponse(generatedAt: now, windows: windows)
    }

    /// The client-side diagnostic kinds that count as a browser error (the same
    /// two `ClientDiagnosticsRoutes` accepts and the dashboard's stuck-student
    /// count keys off): a failed preflight capability check or a kernel
    /// watchdog timeout.
    private static let browserErrorKinds = ["preflight_fail", "watchdog_timeout", "page_unresponsive"]

    /// Trailing-window student submissions, projected to only the columns the
    /// buckets read.  Empty when the course has no setups or no students.
    private func instructorSubmissionPoints(
        setupIDs: [String],
        studentIDs: Set<UUID>,
        since outerStart: Date,
        on db: Database
    ) async throws -> [InstructorSubmissionPoint] {
        guard !setupIDs.isEmpty, !studentIDs.isEmpty else { return [] }
        let submissions = try await APISubmission.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$userID ~~ Array(studentIDs))
            .filter(\.$submittedAt >= outerStart)
            .field(\.$submittedAt)
            .field(\.$userID)
            .field(\.$testSetupID)
            .all()
        return submissions.compactMap { submission in
            guard let submittedAt = submission.submittedAt, let userID = submission.userID else { return nil }
            return InstructorSubmissionPoint(
                submittedAt: submittedAt, userID: userID, testSetupID: submission.testSetupID)
        }
    }

    /// Trailing-window browser-error diagnostic timestamps for the course's
    /// enrolled students, restricted to the two error kinds.  Only the
    /// timestamp is needed — the card counts raw events per bucket so a
    /// post-deploy decline is visible (vs. the dashboard's reconciled
    /// "students stuck right now" gauge).
    private func instructorBrowserErrorDates(
        setupIDs: [String],
        studentIDs: Set<UUID>,
        since outerStart: Date,
        on db: Database
    ) async throws -> [Date] {
        guard !setupIDs.isEmpty, !studentIDs.isEmpty else { return [] }
        return try await APIClientDiagnostic.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$userID ~~ Array(studentIDs))
            .filter(\.$kind ~~ Self.browserErrorKinds)
            .filter(\.$createdAt >= outerStart)
            .field(\.$createdAt)
            .all()
            .compactMap(\.createdAt)
    }

    private func buildInstructorWindow(
        window: MetricsCardWindow,
        now: Date,
        points: [InstructorSubmissionPoint],
        browserErrorDates: [Date]
    ) -> InstructorCardWindowSeries {
        let grid = window.bucketWindow(endingAt: now)

        var submissionsPerBucket = [Int](repeating: 0, count: grid.bucketCount)
        var studentsPerBucket = [Set<UUID>](repeating: [], count: grid.bucketCount)
        var assignmentsPerBucket = [Set<String>](repeating: [], count: grid.bucketCount)
        var browserErrorsPerBucket = [Int](repeating: 0, count: grid.bucketCount)
        var windowStudents: Set<UUID> = []
        var windowAssignments: Set<String> = []
        var windowSubmissions = 0
        var windowBrowserErrors = 0

        for point in points {
            guard let index = grid.bucketIndex(for: point.submittedAt) else { continue }
            submissionsPerBucket[index] += 1
            studentsPerBucket[index].insert(point.userID)
            assignmentsPerBucket[index].insert(point.testSetupID)
            windowSubmissions += 1
            windowStudents.insert(point.userID)
            windowAssignments.insert(point.testSetupID)
        }

        for date in browserErrorDates {
            guard let index = grid.bucketIndex(for: date) else { continue }
            browserErrorsPerBucket[index] += 1
            windowBrowserErrors += 1
        }

        let bucketLabels = (0..<grid.bucketCount).map { index in
            window.label(forBucketStart: grid.bucketStart(forIndex: index))
        }
        // A zero bucket is genuine "no activity" here (counts, not gauges), so
        // the series carries 0 rather than nil — the sparkline draws an empty
        // bar either way, but the headline math stays simple.
        return InstructorCardWindowSeries(
            window: window.rawValue,
            label: window.displayLabel,
            bucketLabels: bucketLabels,
            submissions: MetricsCardSeries(
                headline: windowSubmissions,
                series: submissionsPerBucket.map { Optional($0) }
            ),
            activeStudents: MetricsCardSeries(
                headline: windowStudents.count,
                series: studentsPerBucket.map { Optional($0.count) }
            ),
            activeAssignments: MetricsCardSeries(
                headline: windowAssignments.count,
                series: assignmentsPerBucket.map { Optional($0.count) }
            ),
            browserErrors: MetricsCardSeries(
                headline: windowBrowserErrors,
                series: browserErrorsPerBucket.map { Optional($0) }
            )
        )
    }
}
