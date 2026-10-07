// Tests/APITests/AuthoredBadgeDisplayTests.swift
//
// An authored individual badge shows on every page that shows a submission's
// badges: the submission page, the student dashboard and the staff
// per-student page (#2020). Before, only the submission page evaluated
// authored badges. That page also read the grade with the class-goal bonus,
// while every built-in badge read the raw grade. All badges now read the raw
// grade.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AuthoredBadgeDisplayTests {

    private static let badgeLabel = "Halfway Mark"

    private func authoredBadge(atLeast percent: Double) -> Achievement {
        Achievement(
            id: "halfway", name: "Halfway", scope: .individual,
            conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: percent)],
            reward: AchievementReward(type: .badge, label: Self.badgeLabel))
    }

    /// A class goal that the class has reached, worth one bonus point.
    private let reachedClassGoal = Achievement(
        id: "class_goal", name: "Class Goal", scope: .classWide,
        conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 50)],
        reward: AchievementReward(type: .points, label: "Class Goal", points: 1),
        classFraction: 0.5)

    /// One student, one submission that passes one of two tests (50%), on an
    /// assignment that authors `achievements`. Returns the student cookie,
    /// the student's URL token and the submission id.
    private func seedHalfPassingSubmission(
        setupID: String, achievements: [Achievement], on app: Application
    ) async throws -> (cookie: String, urlToken: String, submissionID: String) {
        let cookie = try await arLoginAsStudent(on: app)
        let student = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
        try await arEnrollStudentInTestCourse(student, on: app)

        let props = TestProperties(language: nil, achievements: achievements)
        let manifest = try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
        try await arInsertSetup(id: setupID, manifest: manifest, on: app)
        try await arInsertAssignment(testSetupID: setupID, title: "Badge Lab", isOpen: true, on: app)

        let submissionID = "\(setupID)_sub"
        _ = try await arInsertSubmission(
            id: submissionID, testSetupID: setupID, userID: try student.requireID(), on: app)
        _ = try await wrInsertResult(
            submissionID: submissionID,
            outcomes: [
                wrMakeOutcome(name: "t1", status: .pass),
                wrMakeOutcome(name: "t2", status: .fail),
            ],
            on: app)
        return (cookie, try student.requireURLToken(), submissionID)
    }

    @Test func anEarnedAuthoredBadgeShowsOnEveryPage() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(
                setupID: "authored_everywhere", achievements: [authoredBadge(atLeast: 50)], on: app)
            let instructorCookie = try await arLoginAsInstructor(on: app)

            let submissionPage = try await getHTML(
                "/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            #expect(submissionPage.contains(Self.badgeLabel), "submission page")

            let dashboard = try await getHTML("/", cookie: seeded.cookie, on: app)
            #expect(dashboard.contains(Self.badgeLabel), "student dashboard")

            let staffPage = try await getHTML(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: seeded.urlToken),
                cookie: instructorCookie, on: app)
            #expect(staffPage.contains(Self.badgeLabel), "staff per-student page")
        }
    }

    @Test func anUnearnedAuthoredBadgeShowsOnNoPage() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedHalfPassingSubmission(
                setupID: "authored_nowhere", achievements: [authoredBadge(atLeast: 60)], on: app)

            let submissionPage = try await getHTML(
                "/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            #expect(!submissionPage.contains(Self.badgeLabel))
            let dashboard = try await getHTML("/", cookie: seeded.cookie, on: app)
            #expect(!dashboard.contains(Self.badgeLabel))
        }
    }

    @Test func aClassGoalBonusDoesNotEarnAnAuthoredBadge() async throws {
        try await withAssignmentRoutesApp { app in
            // Raw grade 1 of 2 points is 50%. The reached class goal adds one
            // point, so the grade with the bonus is 100%.
            let seeded = try await seedHalfPassingSubmission(
                setupID: "authored_bonus",
                achievements: [authoredBadge(atLeast: 100), reachedClassGoal], on: app)
            try await APIAchievementResult(
                testSetupID: "authored_bonus", achievementID: "class_goal",
                studentsMeeting: 1, denominator: 1, progress: 1.0, locked: false,
                evaluatedAt: Date()
            ).save(on: app.db)

            let submissionPage = try await getHTML(
                "/submissions/\(seeded.submissionID)", cookie: seeded.cookie, on: app)
            #expect(submissionPage.contains("100%"), "the page shows the grade with the bonus")
            #expect(
                !submissionPage.contains(Self.badgeLabel),
                "the badge reads the raw 50%, not the 100% with the bonus")
            let dashboard = try await getHTML("/", cookie: seeded.cookie, on: app)
            #expect(!dashboard.contains(Self.badgeLabel))
        }
    }
}
