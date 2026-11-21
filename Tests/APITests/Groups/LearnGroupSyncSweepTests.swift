// Tests/APITests/Groups/LearnGroupSyncSweepTests.swift
//
// The course loop of the LEARN group sync (`sweepLearnGroups`) and its
// monitor. `LearnGroupSyncTests` covers one set's sync and which courses the
// sweep reads; these tests pin the rules around the loop: a set whose read
// fails is logged and the sweep goes on, a course with no client is skipped
// quietly, and the summary line is written only when the groups changed. The
// monitor test runs one real tick through the course's sync identity against
// a scripted D2L. No test reaches the network.

import Core
import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import Vapor
import VaporTesting

@testable import APIServer

// MARK: - Fakes

/// LEARN as the sweep reads it: the Sections of every course, and one
/// classlist. When `sectionsError` is set, the Sections read fails.
private struct SweepLearn: BrightSpaceGrading {
    var sections: [BrightSpaceGroup] = []
    var classlist: [BrightSpaceClasslistEntry] = []
    var sectionsError: BrightSpaceSyncError?

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? { nil }
    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceClasslistEntry] { classlist }
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
    func fetchGroups(
        orgUnitID: String, categoryID: String, on application: Application
    ) async throws -> [BrightSpaceGroup] { [] }
    func fetchSections(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceGroup] {
        if let sectionsError { throw sectionsError }
        return sections
    }
}

/// Keeps every line that a test logger writes.
private final class GroupSyncLogCapture: Sendable {
    struct Line: Sendable {
        let level: Logger.Level
        let message: String
    }

    private let stored = Mutex<[Line]>([])

    var lines: [Line] { stored.withLock { $0 } }

    var logger: Logger {
        var logger = Logger(label: "learn-group-sync.test")
        logger.handler = GroupSyncCapturingLogHandler(capture: self)
        return logger
    }

    func append(_ line: Line) {
        stored.withLock { $0.append(line) }
    }

    func contains(_ level: Logger.Level, _ fragment: String) -> Bool {
        lines.contains { $0.level == level && $0.message.contains(fragment) }
    }
}

private struct GroupSyncCapturingLogHandler: LogHandler {
    let capture: GroupSyncLogCapture

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

@Suite(.serialized, .timeLimit(.minutes(2))) struct LearnGroupSyncSweepTests {

    /// A course bound to `orgUnitID` with a Sections set, and one enrolled
    /// student whose username is `username`. Returns the course and the set.
    private func course(
        _ code: String, orgUnitID: String, username: String, on app: Application
    ) async throws -> (course: APICourse, set: APICourseGroupSet) {
        let course = try await makeTestCourse(on: app, code: code, mode: .closed)
        course.brightspaceOrgUnitID = orgUnitID
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let set = APICourseGroupSet(courseID: courseID, name: "Labs", source: .learnSections)
        try await set.save(on: app.db)
        let student = try await makeTestStudent(on: app, username: username)
        try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: courseID)
        return (course, set)
    }

    private func groupNames(_ set: APICourseGroupSet, on app: Application) async throws -> [String] {
        try await CourseGroupStore.groups(inSet: try set.requireID(), includingRemoved: true, on: app.db)
            .map(\.name)
    }

    private func learn(for username: String) -> SweepLearn {
        SweepLearn(
            sections: [BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501"])],
            classlist: [BrightSpaceClasslistEntry(orgDefinedID: nil, username: username, userID: "501")])
    }

    @Test func aSetWhoseReadFailsIsLoggedAndTheNextCourseIsStillSynced() async throws {
        try await withTestApp { app in
            let failing = try await course("LGFAIL", orgUnitID: "ou-fail", username: "lg_fail", on: app)
            let ready = try await course("LGOK", orgUnitID: "ou-ok", username: "lg_ok", on: app)
            let capture = GroupSyncLogCapture()

            let synced = try await sweepLearnGroups(
                on: app.db,
                resolveClient: { course in
                    course.code == "LGFAIL"
                        ? SweepLearn(sectionsError: .sectionsFetchFailed(orgUnitID: "ou-fail", status: 503))
                        : learn(for: "lg_ok")
                },
                logger: capture.logger,
                application: app)

            #expect(synced == 1)
            #expect(try await groupNames(ready.set, on: app) == ["Lab 101"])
            #expect(try await groupNames(failing.set, on: app).isEmpty)
            #expect(capture.contains(.warning, "LEARN group sync failed for course LGFAIL"))
        }
    }

    @Test func aCourseWithNoClientIsSkippedQuietly() async throws {
        try await withTestApp { app in
            let deferred = try await course("LGNONE", orgUnitID: "ou-none", username: "lg_none", on: app)
            let capture = GroupSyncLogCapture()

            let synced = try await sweepLearnGroups(
                on: app.db, resolveClient: { _ in nil }, logger: capture.logger, application: app)

            #expect(synced == 0)
            #expect(try await groupNames(deferred.set, on: app).isEmpty)
            #expect(capture.lines.isEmpty, "a course with no LEARN identity is a deferral, not a failure")
        }
    }

    @Test func theSweepLogsASummaryOnlyWhenTheGroupsChanged() async throws {
        try await withTestApp { app in
            _ = try await course("LGSUM", orgUnitID: "ou-sum", username: "lg_sum", on: app)
            let client = learn(for: "lg_sum")
            let capture = GroupSyncLogCapture()

            let first = try await sweepLearnGroups(
                on: app.db, resolveClient: { _ in client }, logger: capture.logger, application: app)
            #expect(first == 1)
            #expect(capture.contains(.info, "LEARN group sync for LGSUM:"))
            #expect(capture.contains(.info, "1 groups added or restored, 0 renamed, 0 removed"))
            let linesAfterFirst = capture.lines.count

            let second = try await sweepLearnGroups(
                on: app.db, resolveClient: { _ in client }, logger: capture.logger, application: app)
            #expect(second == 1, "an unchanged set still counts as synced")
            #expect(capture.lines.count == linesAfterFirst, "no summary when nothing changed")
        }
    }

    // MARK: Monitor

    @Test func theMonitorIsOneNamedInstanceAndItsTickSyncsThroughTheCourseIdentity() async throws {
        try await withTestApp { app in
            let monitor = app.learnGroupSyncMonitor
            #expect(monitor.name == "LEARN group sync")
            #expect(monitor === app.learnGroupSyncMonitor)

            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.example", appID: "test-app-id", appKey: "test-app-key", debounceSecs: 90)
            defer { app.brightSpaceAppCredentials = nil }
            let sent = app.useScriptedValence(
                scriptedLearn([
                    "/sections/": ScriptedValenceReply(
                        .ok, #"[{"SectionId": 70, "Name": "Lab 101", "Enrollments": [501]}]"#),
                    "/classlist/": ScriptedValenceReply(
                        .ok,
                        #"{"Items": [{"Identifier": "501", "OrgDefinedId": null, "Username": "lg_mon"}], "PagingInfo": {"Bookmark": "", "HasMoreItems": false}}"#
                    ),
                ]))
            let bound = try await course("LGMON", orgUnitID: "900", username: "lg_mon", on: app)
            let identity = try await makeTestUser(on: app, username: "lg_mon_instructor", role: "instructor")
            let identityID = try identity.requireID()
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "vu", valenceUserKey: "vk", identityName: "LEARN Instructor",
                capturedByUserID: identityID, userID: identityID, on: app.db)
            bound.course.brightspaceSyncUserID = identityID
            try await bound.course.save(on: app.db)

            await monitor.sweepOnce(application: app)
            let setID = try bound.set.requireID()
            let placed = try await !CourseGroupStore.groupIDsByUser(inSet: setID, on: app.db).isEmpty

            #expect(placed, "one tick places the student")
            #expect(try await groupNames(bound.set, on: app) == ["Lab 101"])
            let urls = sent.withLockedValue { $0 }.map(\.url)
            #expect(urls.contains { $0.contains("/900/sections/") })
        }
    }
}
