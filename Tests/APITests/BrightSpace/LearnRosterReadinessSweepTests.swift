// Tests/APITests/BrightSpace/LearnRosterReadinessSweepTests.swift
//
// The course loop of the periodic LEARN roster-readiness sweep
// (`sweepLearnRosterReadiness`) and its monitor. `LearnRosterReadinessTests`
// covers the per-course reconcile; these tests pin the rules around it: a
// course with no org unit is not read, a course whose identity does not
// resolve keeps its students' statuses, and a failure in one course does not
// stop the sweep. The client is an in-memory fake, so no test reaches D2L.

import Core
import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import VaporTesting

@testable import APIServer

// MARK: - Fakes

/// A `BrightSpaceGrading` fake that serves a fixed classlist, or fails the
/// classlist read when `classlistError` is set.
private struct SweepClasslistClient: BrightSpaceGrading {
    var classlist: [BrightSpaceClasslistEntry] = []
    var classlistError: BrightSpaceSyncError?

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? { nil }
    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceClasslistEntry] {
        if let classlistError { throw classlistError }
        return classlist
    }
    func pushGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, earnedPoints: Double,
        on application: Application
    ) async throws {}
    func fetchGradeObject(
        orgUnitID: String, gradeObjectID: String, on application: Application
    ) async throws -> BrightSpaceGradeObject? { nil }
    func clearGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, on application: Application
    ) async throws {}
}

/// The course codes the sweep asked a client for.
private actor ResolveRecorder {
    private(set) var codes: [String] = []
    func record(_ code: String) { codes.append(code) }
}

/// Keeps every log line that a test logger writes.
private final class SweepLogCapture: Sendable {
    struct Line: Sendable {
        let level: Logger.Level
        let message: String
    }

    private let stored = Mutex<[Line]>([])

    var lines: [Line] { stored.withLock { $0 } }

    var logger: Logger {
        var logger = Logger(label: "roster-readiness.test")
        logger.handler = SweepCapturingLogHandler(capture: self)
        return logger
    }

    func append(_ line: Line) {
        stored.withLock { $0.append(line) }
    }

    func contains(_ level: Logger.Level, _ fragment: String) -> Bool {
        lines.contains { $0.level == level && $0.message.contains(fragment) }
    }
}

private struct SweepCapturingLogHandler: LogHandler {
    let capture: SweepLogCapture

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        capture.append(.init(level: event.level, message: "\(event.message)"))
    }
}

// MARK: - Suite

@Suite(.serialized, .timeLimit(.minutes(2))) struct LearnRosterReadinessSweepTests {

    /// A course bound to `orgUnitID`, with one enrolled student whose username
    /// is `username`. Returns the course and the student's enrollment.
    private func makeCourse(
        code: String, orgUnitID: String?, username: String, on app: Application
    ) async throws -> (course: APICourse, enrollment: APICourseEnrollment) {
        let course = try await makeTestCourse(on: app, code: code)
        course.brightspaceOrgUnitID = orgUnitID
        try await course.save(on: app.db)
        let student = try await makeTestUser(on: app, username: username)
        let enrollment = try await makeTestEnrollment(
            on: app, userID: try student.requireID(), courseID: try course.requireID())
        return (course, enrollment)
    }

    private func reload(_ enrollment: APICourseEnrollment, on app: Application) async throws -> APICourseEnrollment {
        try #require(try await APICourseEnrollment.find(try enrollment.requireID(), on: app.db))
    }

    // MARK: Courses the sweep does not read

    @Test func aCourseWithNoOrgUnitIsNeverResolved() async throws {
        try await withTestApp { app in
            _ = try await makeCourse(code: "RSNONE", orgUnitID: nil, username: "rs_none", on: app)
            _ = try await makeCourse(code: "RSEMPTY", orgUnitID: "", username: "rs_empty", on: app)
            let recorder = ResolveRecorder()

            let updated = try await sweepLearnRosterReadiness(
                on: app.db,
                resolveClient: { course in
                    await recorder.record(course.code)
                    return SweepClasslistClient()
                },
                logger: app.logger,
                application: app)

            #expect(updated == 0)
            #expect(await recorder.codes.isEmpty, "a course with no org unit has no classlist to read")
        }
    }

    @Test func aCourseWhoseIdentityDoesNotResolveKeepsItsStatusesAndTheSweepGoesOn() async throws {
        try await withTestApp { app in
            let throwing = try await makeCourse(
                code: "RSTHROW", orgUnitID: "ou-throw", username: "rs_throw", on: app)
            let deferred = try await makeCourse(
                code: "RSDEFER", orgUnitID: "ou-defer", username: "rs_defer", on: app)
            let ready = try await makeCourse(
                code: "RSREADY", orgUnitID: "ou-ready", username: "rs_ready", on: app)
            let capture = SweepLogCapture()

            let updated = try await sweepLearnRosterReadiness(
                on: app.db,
                resolveClient: { course in
                    switch course.code {
                    case "RSTHROW": throw BrightSpaceSyncError.notConfigured
                    case "RSDEFER": return nil
                    default:
                        return SweepClasslistClient(classlist: [
                            BrightSpaceClasslistEntry(orgDefinedID: nil, username: "rs_ready", userID: "d2l-1")
                        ])
                    }
                },
                logger: capture.logger,
                application: app)

            #expect(updated == 1, "only the course with a client is reconciled")
            #expect(try await reload(ready.enrollment, on: app).learnSyncReadiness == .confirmed)
            for skipped in [throwing.enrollment, deferred.enrollment] {
                let row = try await reload(skipped, on: app)
                #expect(row.learnSyncReadiness == .unconfirmed, "never wrongly flagged unreachable")
                #expect(row.brightspaceCheckedAt == nil)
            }
            #expect(capture.contains(.warning, "client resolve failed"))
            #expect(!capture.contains(.warning, "sweep failed"), "a nil client is a deferral, not a failure")
        }
    }

    @Test func aClasslistFailureInOneCourseIsLoggedAndTheNextCourseIsStillReconciled() async throws {
        try await withTestApp { app in
            let failing = try await makeCourse(
                code: "RSFAIL", orgUnitID: "ou-fail", username: "rs_fail", on: app)
            let ready = try await makeCourse(
                code: "RSOK", orgUnitID: "ou-ok", username: "rs_ok", on: app)
            let capture = SweepLogCapture()

            let updated = try await sweepLearnRosterReadiness(
                on: app.db,
                resolveClient: { course in
                    course.code == "RSFAIL"
                        ? SweepClasslistClient(
                            classlistError: .classlistFetchFailed(orgUnitID: "ou-fail", status: 503))
                        : SweepClasslistClient(classlist: [
                            BrightSpaceClasslistEntry(orgDefinedID: nil, username: "rs_ok", userID: "d2l-2")
                        ])
                },
                logger: capture.logger,
                application: app)

            #expect(updated == 1)
            #expect(try await reload(ready.enrollment, on: app).learnSyncReadiness == .confirmed)
            #expect(try await reload(failing.enrollment, on: app).learnSyncReadiness == .unconfirmed)
            #expect(capture.contains(.warning, "Roster readiness sweep failed for course RSFAIL"))
        }
    }

    @Test func theSweepLogsASummaryOnlyWhenAStatusChanged() async throws {
        try await withTestApp { app in
            _ = try await makeCourse(code: "RSSUM", orgUnitID: "ou-sum", username: "rs_sum", on: app)
            let client = SweepClasslistClient(classlist: [
                BrightSpaceClasslistEntry(orgDefinedID: nil, username: "rs_sum", userID: "d2l-3")
            ])
            let capture = SweepLogCapture()

            let first = try await sweepLearnRosterReadiness(
                on: app.db, resolveClient: { _ in client }, logger: capture.logger, application: app)
            #expect(first == 1)
            #expect(
                capture.contains(.info, "Roster readiness for RSSUM: 1 confirmed, 0 unreachable (1 changed)"))
            let linesAfterFirst = capture.lines.count

            let second = try await sweepLearnRosterReadiness(
                on: app.db, resolveClient: { _ in client }, logger: capture.logger, application: app)
            #expect(second == 0, "an unchanged status is not counted again")
            #expect(capture.lines.count == linesAfterFirst, "no summary when nothing changed")
        }
    }

    // MARK: Monitor

    @Test func theMonitorIsOneNamedInstanceAndItsTickLeavesAnUnconnectedCourseAlone() async throws {
        try await withTestApp { app in
            let monitor = app.learnRosterReadinessMonitor
            #expect(monitor.name == "LEARN roster readiness")
            #expect(monitor === app.learnRosterReadinessMonitor)

            // App credentials are set, but the course has no connected
            // identity and there is no deployment-wide one: the tick resolves
            // no client, and the student's status stays as it was.
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.example.edu", appID: "app", appKey: "key", debounceSecs: 90)
            defer { app.brightSpaceAppCredentials = nil }
            let bound = try await makeCourse(
                code: "RSMON", orgUnitID: "ou-mon", username: "rs_mon", on: app)

            monitor.start(application: app)
            var leased = false
            for _ in 0..<200 {
                if try await SweepLease.find("LEARN roster readiness", on: app.db) != nil {
                    leased = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            await monitor.stop()

            #expect(leased, "the first tick runs at start")
            let row = try await reload(bound.enrollment, on: app)
            #expect(row.learnSyncReadiness == .unconfirmed)
            #expect(row.brightspaceCheckedAt == nil)
        }
    }
}
