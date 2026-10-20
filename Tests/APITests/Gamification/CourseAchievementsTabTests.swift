// Tests/APITests/Gamification/CourseAchievementsTabTests.swift
//
// The course Achievements tab (docs/achievement-rewards.md, S4): the page,
// the rows a PUT saves for the active course, the TA floor, and Recompute.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CourseAchievementsTabTests {

    private static let twoLabs = AchievementRow(
        id: "two_labs", name: "Two labs", scope: "individual",
        conditions: [ConditionRow(signal: "assignmentsGraded", comparator: "atLeast", value: 2)])

    private func put(
        _ rows: [AchievementRow], cookie: String, on app: Application
    ) async throws -> (status: HTTPStatus, body: String) {
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .PUT, "/instructor/achievements/rows",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                try req.content.encode(PublishedAssignmentRoutes.AchievementsBody(achievements: rows), as: .json)
            },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    private func testCourse(on app: Application) async throws -> APICourse {
        try #require(try await APICourse.find(try await app.testCourseID(enrollmentMode: .auto), on: app.db))
    }

    @Test func thePageShowsTheThreeSectionsAndTheTab() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let html = try await getHTML("/instructor/achievements", cookie: cookie, on: app)
            #expect(html.contains("Course achievements"))
            #expect(html.contains("Earned so far"))
            #expect(html.contains("Built in"))
            #expect(html.contains("href=\"/instructor/achievements\""))
            #expect(html.contains("data-level=\"course\""))
            #expect(html.contains(WardrobeItem.twoToneRing.displayName))
        }
    }

    @Test func aPutSavesTheRowsOnTheActiveCourse() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let saved = try await put([Self.twoLabs], cookie: cookie, on: app)
            #expect(saved.status == .ok)
            #expect(saved.body.contains("two_labs"))

            let course = try await testCourse(on: app)
            #expect(course.courseAchievements.map(\.id) == ["two_labs"])

            try await app.asyncTest(
                .GET, "/instructor/achievements/rows",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(PublishedAssignmentRoutes.AchievementsResponse.self)
                    #expect(body.achievements.map(\.name) == ["Two labs"])
                })
        }
    }

    @Test func aPutThatTheValidatorRefusesChangesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let grade = AchievementRow(
                name: "Grade", scope: "individual",
                conditions: [ConditionRow(signal: "grade", comparator: "atLeast", value: 50)])
            let refused = try await put([grade], cookie: cookie, on: app)
            #expect(refused.status == .badRequest || refused.status == .unprocessableEntity)
            #expect(try await testCourse(on: app).courseAchievements.isEmpty)
        }
    }

    @Test func aTAMaySaveTheRows() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsCourseTA("course_ach_ta", on: app)
            #expect(try await put([Self.twoLabs], cookie: cookie, on: app).status == .ok)
        }
    }

    @Test func anArchivedCourseRefusesASave() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await testCourse(on: app)
            course.isArchived = true
            try await course.save(on: app.db)
            #expect(try await put([Self.twoLabs], cookie: cookie, on: app).status != .ok)
            #expect(try await testCourse(on: app).courseAchievements.isEmpty)
        }
    }

    @Test func recomputeGrantsEveryEnrolledStudentAndThePageListsThem() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "tab_student", displayName: "Tab Student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            for index in 0..<2 {
                let setupID = "tab_lab_\(index)"
                try await arInsertSetup(id: setupID, on: app)
                try await arInsertAssignment(testSetupID: setupID, title: "Lab \(index)", isOpen: true, on: app)
                try await arInsertSubmission(
                    id: "\(setupID)_sub", testSetupID: setupID, userID: try student.requireID(), on: app)
                try await wrInsertResult(
                    submissionID: "\(setupID)_sub", outcomes: [wrMakeOutcome(name: "t1", status: .pass)], on: app)
            }
            #expect(try await put([Self.twoLabs], cookie: cookie, on: app).status == .ok)

            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/achievements", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/achievements/recompute",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther || res.status == .found)
                    #expect(res.headers.first(name: .location) == "/instructor/achievements?notice=recomputed")
                })

            let awards = try await AchievementAwardStore.awards(for: student.requireID(), on: app.db)
            #expect(awards.map(\.achievementID) == ["two_labs"])

            let html = try await getHTML("/instructor/achievements", cookie: cookie, on: app)
            #expect(html.contains("Tab Student"))
            #expect(html.contains("1 of "))
        }
    }
}
