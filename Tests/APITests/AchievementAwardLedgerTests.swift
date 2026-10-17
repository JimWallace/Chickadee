// Tests/APITests/AchievementAwardLedgerTests.swift
//
// The award ledger (docs/achievement-rewards.md, S1): a student's own result
// page and dashboard store the badges they show, once each, and a regrade
// does not take a stored badge back. A staff view stores nothing. The rows go
// with the assignment and are in the account export.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct AchievementAwardLedgerTests {

    private static let badgeLabel = "Halfway Mark"
    private static let badgeDetail = "Passed half of the tests."

    /// An individual badge for a grade of at least 50%.
    private let halfwayBadge = Achievement(
        id: "halfway", name: "Halfway", detail: AchievementAwardLedgerTests.badgeDetail, scope: .individual,
        conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 50)],
        reward: AchievementReward(type: .badge, label: AchievementAwardLedgerTests.badgeLabel))

    private struct Seeded {
        let cookie: String
        let student: APIUser
        let assignment: APIAssignment
        let submissionID: String
    }

    /// One student, one submission that passes one of two tests (50%), on an
    /// assignment that authors the halfway badge.
    private func seedHalfPassingSubmission(setupID: String, on app: Application) async throws -> Seeded {
        let cookie = try await arLoginAsStudent(on: app)
        let student = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
        try await arEnrollStudentInTestCourse(student, on: app)

        let props = TestProperties(language: nil, achievements: [halfwayBadge])
        let manifest = try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
        try await arInsertSetup(id: setupID, manifest: manifest, on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: setupID, title: "Ledger Lab", isOpen: true, on: app)

        let submissionID = "\(setupID)_sub"
        _ = try await arInsertSubmission(
            id: submissionID, testSetupID: setupID, userID: try student.requireID(), on: app)
        _ = try await wrInsertResult(
            submissionID: submissionID,
            outcomes: [wrMakeOutcome(name: "t1", status: .pass), wrMakeOutcome(name: "t2", status: .fail)],
            on: app)
        return Seeded(cookie: cookie, student: student, assignment: assignment, submissionID: submissionID)
    }

    private func storedAwards(for student: APIUser, on app: Application) async throws -> [APIAchievementAward] {
        try await AchievementAwardStore.awards(for: student.requireID(), on: app.db)
    }

    // MARK: - The pages that write

    @Test func theStudentsOwnResultPageStoresTheBadgeItShows() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_page", on: app)

            let html = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            #expect(html.contains(Self.badgeLabel))

            let awards = try await storedAwards(for: seeded.student, on: app)
            let award = try #require(awards.first)
            #expect(awards.count == 1)
            #expect(award.achievementLevel == .assignment)
            #expect(award.ownerID == "ledger_page")
            #expect(award.achievementID == "halfway")
            #expect(award.submissionID == seeded.submissionID)
            #expect(award.label == Self.badgeLabel)
            #expect(award.detail == Self.badgeDetail)
            #expect(award.earnedAt != nil)
        }
    }

    @Test func twoLoadsStoreTheBadgeOnce() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_twice", on: app)

            _ = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            _ = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            _ = try await getHTML("/", cookie: seeded.cookie, on: app)

            #expect(try await storedAwards(for: seeded.student, on: app).count == 1)
        }
    }

    @Test func theStudentsDashboardStoresTheBadgeItShows() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_dash", on: app)

            let html = try await getHTML("/", cookie: seeded.cookie, on: app)
            #expect(html.contains(Self.badgeLabel))

            let awards = try await storedAwards(for: seeded.student, on: app)
            #expect(awards.map(\.achievementID) == ["halfway"])
            #expect(awards.first?.submissionID == seeded.submissionID)
        }
    }

    @Test func aRegradeDoesNotTakeAStoredBadgeBack() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_regrade", on: app)
            _ = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)

            // A suite edit regrades the submission, and it now passes nothing.
            try await APIResult.query(on: app.db).filter(\.$submissionID == seeded.submissionID).delete()
            _ = try await wrInsertResult(
                submissionID: seeded.submissionID,
                outcomes: [wrMakeOutcome(name: "t1", status: .fail), wrMakeOutcome(name: "t2", status: .fail)],
                on: app)

            // The page tells the truth about this run, and the ledger keeps
            // what the student earned.
            let html = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            #expect(!html.contains(Self.badgeLabel))
            #expect(try await storedAwards(for: seeded.student, on: app).map(\.achievementID) == ["halfway"])
        }
    }

    @Test func aStaffViewStoresNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_staff", on: app)
            let instructorCookie = try await arLoginAsInstructor(on: app)

            let html = try await getHTML(
                "/submissions/\(seeded.submissionID)", cookie: instructorCookie, on: app)
            #expect(html.contains(Self.badgeLabel))
            #expect(try await storedAwards(for: seeded.student, on: app).isEmpty)
        }
    }

    // MARK: - Where the rows go

    @Test func deletingTheAssignmentDeletesItsAwards() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_delete", on: app)
            _ = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            #expect(try await storedAwards(for: seeded.student, on: app).count == 1)

            let instructorCookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: instructorCookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(seeded.assignment.publicID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            #expect(try await storedAwards(for: seeded.student, on: app).isEmpty)
        }
    }

    @Test func deletingTheCourseDeletesItsAwards() async throws {
        let app = try await makeTestApp(prefix: "chickadee-delete-awards")
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("delete_awards_admin", on: app)
            let student = try await makeTestUser(on: app, username: "awards_student", role: "student")
            let course = try await makeTestCourse(on: app, code: "AWD101", name: "Awards", archived: true)
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_awards_delete", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "setup_awards_delete", courseID: courseID)
            let badge = AchievementBadge(id: "halfway", label: Self.badgeLabel, tooltip: Self.badgeDetail)
            try await AchievementAwardStore.record(
                [badge], earnedBy: student.requireID(), testSetupID: "setup_awards_delete", submissionID: "sub_a",
                on: app.db)
            // An award on another course's setup stays.
            try await AchievementAwardStore.record(
                [badge], earnedBy: student.requireID(), testSetupID: "setup_elsewhere", submissionID: "sub_b",
                on: app.db)

            let path = "/admin/courses/\(courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            #expect(try await APICourse.find(courseID, on: app.db) == nil)
            #expect(try await storedAwards(for: student, on: app).map(\.ownerID) == ["setup_elsewhere"])
        }
    }

    @Test func theExportCarriesTheAwards() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_export", on: app)
            _ = try await getHTML("/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)

            let content = try await gatherDataExportContent(for: seeded.student, on: app.db)
            let award = try #require(content.profile.achievementAwards?.first)
            #expect(content.profile.achievementAwards?.count == 1)
            #expect(award.level == "assignment")
            #expect(award.owner == "ledger_export")
            #expect(award.achievementID == "halfway")
            #expect(award.submissionID == seeded.submissionID)
            #expect(award.label == Self.badgeLabel)
            #expect(
                dataExportReadme(username: "teststudent", generatedAt: Date()).contains("achievements you have earned"))
        }
    }

    // MARK: - The store

    @Test func theStoreKeepsTheFirstSubmissionAndCaption() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_store", on: app)
            let userID = try seeded.student.requireID()
            let first = AchievementBadge(id: "halfway", label: "First caption", tooltip: "First tooltip")
            let renamed = AchievementBadge(id: "halfway", label: "Renamed", tooltip: "Renamed tooltip")
            let other = AchievementBadge(id: "other", label: "Other", tooltip: "Other tooltip")

            let written = try await AchievementAwardStore.record(
                [first, first], earnedBy: userID, testSetupID: "ledger_store", submissionID: "sub_a", on: app.db)
            #expect(written.count == 1)

            let again = try await AchievementAwardStore.record(
                [renamed, other], earnedBy: userID, testSetupID: "ledger_store", submissionID: "sub_b", on: app.db)
            #expect(again.map(\.achievementID) == ["other"])

            let stored = try await storedAwards(for: seeded.student, on: app)
            let halfway = try #require(stored.first { $0.achievementID == "halfway" })
            #expect(stored.count == 2)
            #expect(halfway.label == "First caption")
            #expect(halfway.submissionID == "sub_a")
        }
    }

    @Test func theSameBadgeOnTwoAssignmentsIsTwoAwards() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(setupID: "ledger_two_a", on: app)
            let userID = try seeded.student.requireID()
            let badge = AchievementBadge(id: "halfway", label: Self.badgeLabel, tooltip: Self.badgeDetail)

            try await AchievementAwardStore.record(
                [badge], earnedBy: userID, testSetupID: "ledger_two_a", submissionID: "sub_a", on: app.db)
            try await AchievementAwardStore.record(
                [badge], earnedBy: userID, testSetupID: "ledger_two_b", submissionID: "sub_b", on: app.db)
            #expect(try await storedAwards(for: seeded.student, on: app).count == 2)

            try await AchievementAwardStore.deleteAwards(forTestSetups: ["ledger_two_a"], on: app.db)
            #expect(try await storedAwards(for: seeded.student, on: app).map(\.ownerID) == ["ledger_two_b"])
        }
    }
}
