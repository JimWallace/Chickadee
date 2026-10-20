// Tests for get_course_achievements / update_course_achievements
// (docs/achievement-rewards.md, S5): the course list round-trips through the
// same validation as the web tab, a refused row changes nothing, and the
// schema offers only what the course level accepts.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CourseAchievementsToolsTests {

    private static let twoLabs = AchievementRow(
        id: "two_labs", name: "Two labs", scope: "individual",
        conditions: [ConditionRow(signal: "assignmentsGraded", comparator: "atLeast", value: 2)])

    private func course(of assignment: APIAssignment, on db: any Database) async throws -> APICourse {
        try #require(try await APICourse.find(assignment.courseID, on: db))
    }

    @Test func updateThenGetRoundTripsTheCourseList() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_course_ach")
            var listed = Self.twoLabs
            listed.conditions = [
                ConditionRow(
                    signal: "assignmentsFullMarks", comparator: "atLeast", value: 1, targetKind: "assignments",
                    targetRef: assignment.publicID)
            ]
            listed.id = "listed"
            let updated = try await UpdateCourseAchievementsTool().execute(
                .init(courseCode: "CS246", achievements: [Self.twoLabs, listed]), mcpContext(app, scopes: [.write]))
            #expect(updated.achievements.map(\.id) == ["two_labs", "listed"])
            #expect(updated.courseCode == "CS246")

            let read = try await GetCourseAchievementsTool().execute(
                .init(courseCode: "CS246"), mcpContext(app, scopes: [.read]))
            #expect(read.achievements.map(\.name) == ["Two labs", "Two labs"])
            #expect(read.achievements.last?.conditions?.first?.targetRef == assignment.publicID)
            #expect(try await course(of: assignment, on: app.db).courseAchievements.count == 2)

            let cleared = try await UpdateCourseAchievementsTool().execute(
                .init(courseCode: "CS246", achievements: []), mcpContext(app, scopes: [.write]))
            #expect(cleared.achievements.isEmpty)
        }
    }

    @Test func aRowTheCourseLevelRefusesChangesNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_course_ach_refuse")
            let grade = AchievementRow(
                name: "Grade", scope: "individual",
                conditions: [ConditionRow(signal: "grade", comparator: "atLeast", value: 50)])
            let unknownSection = AchievementRow(
                name: "Unit 9", scope: "individual",
                conditions: [
                    ConditionRow(
                        signal: "assignmentsGraded", comparator: "atLeast", value: 1, targetKind: "courseSection",
                        targetRef: "Unit 9")
                ])
            for row in [grade, unknownSection] {
                await #expect(throws: MCPToolError.self) {
                    _ = try await UpdateCourseAchievementsTool().execute(
                        .init(courseCode: "CS246", achievements: [row]), mcpContext(app, scopes: [.write]))
                }
            }
            #expect(try await course(of: assignment, on: app.db).courseAchievements.isEmpty)
        }
    }

    @Test func shapesTheCourseLevelRefusesAreRefusedThroughTheTool() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await seedMCPAssignment(on: app, setupID: "setup_course_ach_shapes")
            let atMost = AchievementRow(
                name: "At most", scope: "individual",
                conditions: [ConditionRow(signal: "assignmentsGraded", comparator: "atMost", value: 2)])
            let noFloor = AchievementRow(
                name: "No floor", scope: "individual",
                conditions: [ConditionRow(signal: "assignmentsAtGrade", comparator: "atLeast", value: 2)])
            for rows in [[atMost], [noFloor], [Self.twoLabs, Self.twoLabs]] {
                await #expect(throws: MCPToolError.self) {
                    _ = try await UpdateCourseAchievementsTool().execute(
                        .init(courseCode: "CS246", achievements: rows), mcpContext(app, scopes: [.write]))
                }
            }
        }
    }

    @Test func aStudentOfTheCourseCannotWriteIt() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await seedMCPAssignment(on: app, setupID: "setup_course_ach_student")
            let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == mcpTestSubject).first())
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == user.requireID())
                    .filter(\.$course.$id == assignment.courseID)
                    .first())
            enrollment.role = .student
            try await enrollment.save(on: app.db)
            await #expect(throws: (any Error).self) {
                _ = try await UpdateCourseAchievementsTool().execute(
                    .init(courseCode: "CS246", achievements: [Self.twoLabs]), mcpContext(app, scopes: [.write]))
            }
            #expect(try await course(of: assignment, on: app.db).courseAchievements.isEmpty)
        }
    }

    /// The value at `path` in a JSON object, following object keys.
    private static func value(at path: [String], in json: Any) -> Any? {
        path.reduce(json as Any?) { node, key in (node as? [String: Any])?[key] }
    }

    @Test func theCourseRowSchemaOffersOnlyCourseSignals() throws {
        let data = try JSONEncoder().encode(UpdateCourseAchievementsTool.inputSchema)
        let json = try JSONSerialization.jsonObject(with: data)
        let row = ["properties", "achievements", "items"]
        let condition = row + ["properties", "conditions", "items", "properties"]
        let signals = try #require(Self.value(at: condition + ["signal", "enum"], in: json) as? [String])
        #expect(Set(signals) == Set(AchievementSignal.allCases.filter(\.readsTheCourse).map(\.rawValue)))
        let comparators = try #require(Self.value(at: condition + ["comparator", "enum"], in: json) as? [String])
        #expect(comparators == ["atLeast"])
        let scopes = try #require(Self.value(at: row + ["properties", "scope", "enum"], in: json) as? [String])
        #expect(scopes == ["individual"])
        #expect(Self.value(at: row + ["properties", "recordDimension"], in: json) == nil)
    }

    @Test func theCourseCommaListNamesExactlyTheCourseSignals() {
        let listed = Set(MCPAchievementSignalProse.courseCommaList.components(separatedBy: ", "))
        #expect(listed == Set(AchievementSignal.allCases.filter(\.readsTheCourse).map(\.rawValue)))
    }
}
