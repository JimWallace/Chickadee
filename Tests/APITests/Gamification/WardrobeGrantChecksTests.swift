// Tests/APITests/Gamification/WardrobeGrantChecksTests.swift
//
// The result page's wardrobe grant runs only when the student's results have
// changed since the last complete grant (`WardrobeGrantChecks`). A new
// result, or a new process, runs it again.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct WardrobeGrantChecksTests {

    /// Gives `userID` a full-marks graded submission on a later attempt.
    private func gradeFullMarks(
        _ id: String, setupID: String, userID: UUID, on app: Application
    ) async throws {
        if try await APITestSetup.find(setupID, on: app.db) == nil {
            _ = try await wrInsertSetup(id: setupID, on: app)
            try await wrInsertAssignment(testSetupID: setupID, title: "Lab \(setupID)", isOpen: true, on: app)
        }
        _ = try await wrInsertSubmission(id: id, testSetupID: setupID, userID: userID, attemptNumber: 2, on: app)
        _ = try await wrInsertResult(
            submissionID: id, outcomes: [wrMakeOutcome(name: "test0.sh", status: .pass)], on: app)
    }

    private func clearUnlocks(of userID: UUID, on app: Application) async throws {
        try await APIWardrobeUnlock.query(on: app.db).filter(\.$userID == userID).delete()
    }

    @Test func theGrantSkipsUnchangedResultsAndRunsOnANewOne() async throws {
        try await withTestApp { app in
            let student = try await makeTestUser(on: app, username: "wgc_student").requireID()
            for index in 1...3 {
                try await gradeFullMarks("wgc_\(index)", setupID: "wgc_lab\(index)", userID: student, on: app)
            }
            let checks = WardrobeGrantChecks()

            let first = try await WardrobeUnlockStore.grantNew(for: student, on: app.db, checks: checks)
            #expect(!first.isEmpty, "three full marks on later attempts earn an item")

            // Nothing new arrived: the next load does not read the history,
            // so an unlock removed by hand is not granted again here.
            try await clearUnlocks(of: student, on: app)
            let unchanged = try await WardrobeUnlockStore.grantNew(for: student, on: app.db, checks: checks)
            #expect(unchanged.isEmpty)
            #expect(try await WardrobeUnlockStore.unlocked(for: student, on: app.db).isEmpty)

            // A new result changes the fingerprint, so the grant runs again.
            try await gradeFullMarks("wgc_4", setupID: "wgc_lab4", userID: student, on: app)
            let afterNew = try await WardrobeUnlockStore.grantNew(for: student, on: app.db, checks: checks)
            #expect(Set(afterNew).isSuperset(of: Set(first)))

            // A new process starts with no fingerprints and grants.
            try await clearUnlocks(of: student, on: app)
            let fresh = try await WardrobeUnlockStore.grantNew(
                for: student, on: app.db, checks: WardrobeGrantChecks())
            #expect(!fresh.isEmpty)
        }
    }

    @Test func theFingerprintCountsOnlyTheStudentsOwnResults() async throws {
        try await withTestApp { app in
            let student = try await makeTestUser(on: app, username: "wgc_fp").requireID()
            let other = try await makeTestUser(on: app, username: "wgc_other").requireID()
            let empty = try #require(try await WardrobeUnlockStore.gradedFingerprint(for: student, on: app.db))
            #expect(empty == WardrobeGradedFingerprint(count: 0, latest: nil, assignments: nil))

            try await gradeFullMarks("wgc_fp1", setupID: "wgc_fp_lab", userID: student, on: app)
            try await gradeFullMarks("wgc_fp2", setupID: "wgc_fp_lab", userID: other, on: app)
            let one = try #require(try await WardrobeUnlockStore.gradedFingerprint(for: student, on: app.db))
            #expect(one.count == 1)
            #expect(one.latest != nil)
            #expect(one.assignments != nil)
        }
    }

    @Test func aDueDateOrConceptEditChangesTheFingerprint() async throws {
        try await withTestApp { app in
            let student = try await makeTestUser(on: app, username: "wgc_edit").requireID()
            try await gradeFullMarks("wgc_e1", setupID: "wgc_edit_lab", userID: student, on: app)
            let before = try #require(try await WardrobeUnlockStore.gradedFingerprint(for: student, on: app.db))

            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$testSetupID == "wgc_edit_lab").first())
            assignment.dueAt = Date().addingTimeInterval(7 * 24 * 3600)
            try await assignment.save(on: app.db)
            let afterDue = try #require(try await WardrobeUnlockStore.gradedFingerprint(for: student, on: app.db))
            #expect(afterDue != before)

            assignment.conceptRaw = AssignmentConcept.allCases.first?.rawValue
            try await assignment.save(on: app.db)
            let afterConcept = try #require(
                try await WardrobeUnlockStore.gradedFingerprint(for: student, on: app.db))
            #expect(afterConcept != afterDue)
            #expect(afterConcept.count == before.count)
        }
    }

    @Test func theMapIsBounded() async {
        let checks = WardrobeGrantChecks(capacity: 2)
        let fingerprint = WardrobeGradedFingerprint(count: 1, latest: nil, assignments: nil)
        let first = UUID()
        await checks.recordComplete(first, fingerprint)
        await checks.recordComplete(UUID(), fingerprint)
        await checks.recordComplete(UUID(), fingerprint)
        #expect(await !checks.isUnchanged(first, fingerprint), "reaching the capacity clears the map")
    }
}
