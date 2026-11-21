// Tests/APITests/Assignments/AssignmentDeadlineMonitorTests.swift
//
// The assignment deadline monitor and the group-session refusal text. The
// sweep functions (`openScheduledAssignments`, `closeExpiredAssignments`)
// have their own tests; these pin that one monitor tick runs both, in one
// pass, and what a student reads when a per-group activity refuses them.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct AssignmentDeadlineMonitorTests {

    /// One tick opens an assignment whose open date has arrived and closes one
    /// whose due date has passed. An assignment that waits on validation stays
    /// closed, and one with an active deadline override stays open.
    @Test func oneTickOpensTheScheduledAndClosesTheExpired() async throws {
        try await withTestApp(prefix: "chickadee-deadline-monitor") { app in
            let monitor = app.assignmentDeadlineMonitor
            #expect(monitor.name == "Assignment deadline")
            #expect(monitor === app.assignmentDeadlineMonitor)

            let course = try await makeTestCourse(on: app, code: "DLMON")
            let courseID = try course.requireID()
            let hourAgo = Date().addingTimeInterval(-3600)
            let tomorrow = Date().addingTimeInterval(86_400)

            func assignment(_ title: String, open: Bool, dueAt: Date?) async throws -> APIAssignment {
                let setupID = "ts_\(UUID().uuidString.lowercased().prefix(8))"
                _ = try await makeTestSetup(on: app, id: setupID, courseID: courseID)
                return try await makeTestAssignment(
                    on: app, testSetupID: setupID, courseID: courseID, title: title,
                    dueAt: dueAt, isOpen: open)
            }

            let scheduled = try await assignment("Scheduled", open: false, dueAt: tomorrow)
            scheduled.startsAt = hourAgo
            try await scheduled.save(on: app.db)

            let blocked = try await assignment("Blocked", open: false, dueAt: tomorrow)
            blocked.startsAt = hourAgo
            blocked.validationStatus = "failed"
            try await blocked.save(on: app.db)

            let expired = try await assignment("Expired", open: true, dueAt: hourAgo)

            let overridden = try await assignment("Overridden", open: true, dueAt: hourAgo)
            overridden.deadlineOverrideActive = true
            try await overridden.save(on: app.db)

            func visibility(_ row: APIAssignment) async throws -> AssignmentVisibility? {
                try await APIAssignment.find(row.id, on: app.db)?.visibility
            }

            monitor.start(application: app)
            var swept = false
            for _ in 0..<200 {
                if try await visibility(scheduled) == .open, try await visibility(expired) == .closed {
                    swept = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            await monitor.stop()

            #expect(swept, "the first tick runs at start")
            let opened = try #require(try await APIAssignment.find(scheduled.id, on: app.db))
            #expect(opened.startsAt == nil, "the open date is consumed")
            #expect(try await visibility(blocked) == .closed)
            #expect(try await visibility(overridden) == .open)
        }
    }
}

@Suite struct AssignmentSubmissionGateErrorTextTests {

    @Test func aStudentOutsideEveryGroupSessionIsToldToJoinByTheCode() {
        let error = AssignmentSubmissionGateError.notInGroupSession
        #expect(error.status == .forbidden)
        #expect(error.reason == "This activity runs in your lab. Enter the code on the screen at /join to take part.")
    }

    @Test(arguments: [
        AssignmentSubmissionGateError.closed,
        .activityNotYetOpen(opensAtText: "10:00"),
        .activityClosed(closedAtText: "11:00"),
        .notInGroupSession,
    ])
    func everyGateRefusalIsForbidden(_ error: AssignmentSubmissionGateError) {
        #expect(error.status == .forbidden)
        #expect(!error.reason.isEmpty)
    }
}
