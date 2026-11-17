// Tests/APITests/MCP/AdminMCPUsageSummaryTests.swift
//
// get_usage_summary: usage statistics for annual reporting. These tests pin
// the term scoping (a course counts in its term, whatever the date), the
// distinct-person counting across courses, the exclusion of staff and
// validation runs from student numbers, the "mine" scope, the small-course
// withholding, and the PII guarantee (no user identifier in the output).

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminMCPUsageSummaryTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "admin-mcp-usage")
    }

    private func context(subject: String) -> AdminToolContext {
        AdminToolContext(request: makeTestRequest(on: app), subject: subject, grantedScopes: [.read])
    }

    private func term(_ label: String) throws -> AcademicTerm {
        try #require(AcademicTerm(shortLabel: label))
    }

    /// A course in `termLabel` with one assignment, `students` enrolled
    /// students, and one submission from each of the first `submitters`.
    @discardableResult
    private func seedCourse(
        code: String, termLabel: String, students: [APIUser], submitters: Int,
        staff: [(APIUser, CourseRole)] = []
    ) async throws -> APICourse {
        let course = APICourse(code: code, name: "Course \(code)", term: try term(termLabel))
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "\(code.lowercased())_\(termLabel.lowercased())"
        _ = try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        _ = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        for student in students {
            try await APICourseEnrollment(userID: try student.requireID(), courseID: courseID, role: .student)
                .save(on: app.db)
        }
        for (user, role) in staff {
            try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role)
                .save(on: app.db)
        }
        for (index, student) in students.prefix(submitters).enumerated() {
            _ = try await makeTestSubmission(
                on: app, id: "\(setupID)_s\(index)", setupID: setupID, userID: try student.requireID())
        }
        return course
    }

    private func students(_ prefix: String, _ count: Int) async throws -> [APIUser] {
        var users: [APIUser] = []
        for index in 0..<count {
            users.append(try await makeTestStudent(on: app, username: "\(prefix)-\(index)"))
        }
        return users
    }

    @Test func countsByTermAndDeduplicatesPeopleAcrossCourses() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "us-admin", role: "admin")
            let shared = try await students("us-shared", 6)
            let other = try await students("us-other", 2)
            // Winter: six students, four submit. Fall: the same six plus two
            // more, all eight submit. A course in another year is not counted.
            try await seedCourse(code: "US101", termLabel: "W26", students: shared, submitters: 4)
            try await seedCourse(code: "US102", termLabel: "F26", students: shared + other, submitters: 8)
            try await seedCourse(code: "US103", termLabel: "F25", students: other, submitters: 2)

            let report = try await GetUsageSummaryTool().execute(
                .init(year: 2026), context(subject: "us-admin"))

            #expect(report.terms == ["W26", "S26", "F26"])
            #expect(report.totals.courses == 2)
            #expect(report.totals.distinctCourseCodes == 2)
            #expect(report.totals.enrolledStudents == 8)
            #expect(report.totals.activeStudents == 8)
            #expect(report.totals.assignments == 2)
            #expect(report.totals.submissions.student == 12)
            #expect(report.byTerm.map(\.term) == ["W26", "S26", "F26"])
            let winter = try #require(report.byTerm.first { $0.term == "W26" })
            #expect(winter.totals.activeStudents == 4)
            #expect(winter.totals.submissions.student == 4)
            let spring = try #require(report.byTerm.first { $0.term == "S26" })
            #expect(spring.totals.courses == 0)
            #expect(report.perCourse == nil)
        }
    }

    @Test func explicitTermsSelectAnAcademicYear() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "us-admin-ay", role: "admin")
            let roster = try await students("us-ay", 5)
            try await seedCourse(code: "AY101", termLabel: "F25", students: roster, submitters: 5)
            try await seedCourse(code: "AY102", termLabel: "F26", students: roster, submitters: 5)

            let report = try await GetUsageSummaryTool().execute(
                .init(terms: ["S26", "f25", "W26"]), context(subject: "us-admin-ay"))
            #expect(report.terms == ["F25", "W26", "S26"])
            #expect(report.totals.courses == 1)
            #expect(report.totals.submissions.student == 5)
        }
    }

    @Test func staffAndValidationRunsAreNotStudentWork() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "us-admin-st", role: "admin")
            let roster = try await students("us-st", 5)
            let prof = try await makeTestUser(on: app, username: "us-st-prof", role: "user")
            let ta = try await makeTestUser(on: app, username: "us-st-ta", role: "user")
            try await seedCourse(
                code: "ST101", termLabel: "W26", students: roster, submitters: 2,
                staff: [(prof, .instructor), (ta, .ta)])
            // The instructor submits as a student would, and validates.
            _ = try await makeTestSubmission(
                on: app, id: "st_prof_student", setupID: "st101_w26", userID: try prof.requireID())
            _ = try await makeTestSubmission(
                on: app, id: "st_prof_validation", setupID: "st101_w26", userID: try prof.requireID(),
                kind: APISubmission.Kind.validation)

            let report = try await GetUsageSummaryTool().execute(
                .init(terms: ["W26"]), context(subject: "us-admin-st"))
            #expect(report.totals.instructors == 1)
            #expect(report.totals.teachingAssistants == 1)
            #expect(report.totals.enrolledStudents == 5)
            #expect(report.totals.activeStudents == 2)
            #expect(report.totals.submissions.validation == 1)
            // The staff submission is a student-kind row, so it counts as a
            // submission, but its author is not an active student.
            #expect(report.totals.submissions.student == 3)
        }
    }

    @Test func labOpeningsCountAsActivity() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "us-admin-lab", role: "admin")
            let roster = try await students("us-lab", 5)
            let course = try await seedCourse(code: "LB101", termLabel: "W26", students: roster, submitters: 0)
            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$courseID == course.requireID()).first())
            for student in roster.prefix(3) {
                try await APIAssignmentParticipation(
                    userID: try student.requireID(), assignmentID: try assignment.requireID()
                ).save(on: app.db)
            }

            let report = try await GetUsageSummaryTool().execute(
                .init(terms: ["W26"]), context(subject: "us-admin-lab"))
            #expect(report.totals.labParticipations == 3)
            #expect(report.totals.activeStudents == 3)
            #expect(report.totals.submissions.student == 0)
            #expect(report.totals.submissions.medianPerActiveStudent == nil)
        }
    }

    @Test func mineScopeCountsOnlyCoursesTheCallerInstructs() async throws {
        try await withApp(app) { app in
            let admin = try await makeTestUser(on: app, username: "us-admin-mine", role: "admin")
            let roster = try await students("us-mine", 5)
            try await seedCourse(
                code: "MN101", termLabel: "W26", students: roster, submitters: 5, staff: [(admin, .instructor)])
            try await seedCourse(code: "MN102", termLabel: "W26", students: roster, submitters: 1)
            // A TA enrollment is not "mine".
            try await seedCourse(
                code: "MN103", termLabel: "W26", students: roster, submitters: 1, staff: [(admin, .ta)])

            let mine = try await GetUsageSummaryTool().execute(
                .init(terms: ["W26"], scope: "mine", includePerCourse: true),
                context(subject: "us-admin-mine"))
            #expect(mine.totals.courses == 1)
            #expect(mine.perCourse?.map(\.courseCode) == ["MN101"])
            #expect(mine.totals.submissions.student == 5)

            let all = try await GetUsageSummaryTool().execute(
                .init(terms: ["W26"]), context(subject: "us-admin-mine"))
            #expect(all.totals.courses == 3)

            let narrowed = try await GetUsageSummaryTool().execute(
                .init(terms: ["W26"], courses: ["mn102-w26"]), context(subject: "us-admin-mine"))
            #expect(narrowed.totals.courses == 1)
            #expect(narrowed.totals.submissions.student == 1)
        }
    }

    @Test func smallCoursesWithholdStudentCountsAndOutputCarriesNoIdentifiers() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "us-admin-pii", role: "admin")
            let few = try await students("us-pii-few", 3)
            let many = try await students("us-pii-many", 6)
            try await seedCourse(code: "PI101", termLabel: "W26", students: few, submitters: 3)
            try await seedCourse(code: "PI102", termLabel: "W26", students: many, submitters: 6)

            let report = try await GetUsageSummaryTool().execute(
                .init(terms: ["W26"], includePerCourse: true), context(subject: "us-admin-pii"))
            let small = try #require(report.perCourse?.first { $0.courseCode == "PI101" })
            #expect(small.smallCourse)
            #expect(small.enrolledStudents == nil)
            #expect(small.activeStudents == nil)
            #expect(small.studentSubmissions == 3)
            let large = try #require(report.perCourse?.first { $0.courseCode == "PI102" })
            #expect(!large.smallCourse)
            #expect(large.enrolledStudents == 6)
            // The totals still include the small course.
            #expect(report.totals.enrolledStudents == 9)

            let json = try #require(String(bytes: JSONEncoder().encode(report), encoding: .utf8))
            for user in few + many {
                #expect(!json.contains(try user.requireID().uuidString))
                #expect(!json.contains(user.username))
            }
            #expect(!json.lowercased().contains("userid"))
        }
    }

    @Test func courseWithoutATermIsPlacedByCreationDate() throws {
        let course = APICourse(code: "NT101", name: "No term")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Toronto"))
        course.createdAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))
        let placed = try #require(UsageStatisticsBuilder.placement(of: course))
        #expect(placed.term.shortLabel == "F26")
        #expect(placed.inferred)
    }

    @Test func rejectsBadTermsAndYears() async throws {
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "us-admin-bad", role: "admin")
            await #expect(throws: MCPToolError.self) {
                _ = try await GetUsageSummaryTool().execute(
                    .init(terms: ["Fall 2026"]), context(subject: "us-admin-bad"))
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await GetUsageSummaryTool().execute(
                    .init(year: 1999), context(subject: "us-admin-bad"))
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await GetUsageSummaryTool().execute(
                    .init(scope: "everyone"), context(subject: "us-admin-bad"))
            }
        }
    }

    @Test func medianOfSubmissionCounts() {
        #expect(UsageTotals.median([]) == nil)
        #expect(UsageTotals.median([3]) == 3)
        #expect(UsageTotals.median([1, 5, 2]) == 2)
        #expect(UsageTotals.median([4, 1, 2, 3]) == 2.5)
    }
}
