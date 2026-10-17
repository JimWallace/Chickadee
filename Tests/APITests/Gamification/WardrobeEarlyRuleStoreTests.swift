// Tests/APITests/Gamification/WardrobeEarlyRuleStoreTests.swift
//
// The server side of the `dreamy` face's early rule (docs/student-wardrobe.md,
// E4): the store measures each submission against its assignment's own due
// date, from the server's receipt time, and an assignment with no due date
// counts for nothing.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct WardrobeEarlyRuleStoreTests {

    private static let day: TimeInterval = 24 * 60 * 60

    /// One graded submission of the signed-in student on a new assignment
    /// due `dueIn` from now, or with no due date.
    private func submit(setupID: String, dueIn: TimeInterval?, on app: Application) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrInsertSetup(id: setupID, on: app)
        try await wrInsertAssignment(
            testSetupID: setupID, title: "Lab \(setupID)", isOpen: true,
            dueAt: dueIn.map { Date().addingTimeInterval($0) }, on: app)
        try await wrInsertSubmission(id: "sub_\(setupID)", testSetupID: setupID, userID: student.requireID(), on: app)
        try await wrInsertResult(
            submissionID: "sub_\(setupID)", outcomes: [wrMakeOutcome(name: "t.sh", tier: .pub, status: .fail)], on: app)
    }

    @Test func onlyASubmissionTwoDaysBeforeItsOwnDueDateIsEarly() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await submit(setupID: "early_a", dueIn: 3 * Self.day, on: app)
            try await submit(setupID: "early_b", dueIn: 3 * Self.day, on: app)
            try await submit(setupID: "close", dueIn: Self.day, on: app)
            try await submit(setupID: "late", dueIn: -Self.day, on: app)
            try await submit(setupID: "undated", dueIn: nil, on: app)

            let progress = try await WardrobeUnlockStore.progress(for: student.requireID(), on: app.db)
            #expect(progress.earlyAssignments == 2)
            #expect(!WardrobeItem.earned(by: progress).contains(.dreamyFace))

            try await submit(setupID: "early_c", dueIn: 5 * Self.day, on: app)
            let after = try await WardrobeUnlockStore.progress(for: student.requireID(), on: app.db)
            #expect(after.earlyAssignments == 3)
            #expect(WardrobeItem.earned(by: after).contains(.dreamyFace))
        }
    }
}
