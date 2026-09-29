// Tests/APITests/InstructorActivityPageTests.swift
//
// The Activity tab: rows grouped under Today / Yesterday / date headings in the
// course timezone, the category tile for each kind of event, the person select
// of course staff, and the rendered rows.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorActivityPageTests {

    private let toronto = TimeZone(identifier: "America/Toronto") ?? .current

    /// A row at `date` with everything else fixed.
    private func row(at date: Date, actor: String = "prof") -> CourseActivityRow {
        CourseActivityRow(
            timestamp: "", timestampISO: "", actor: actor, category: "Content edit",
            summary: "Edited", target: "Lab", detail: "v2", link: nil, occurredAt: date,
            clockText: "", categoryKey: "edit", tileKind: "notebook", iconHref: "#i-pencil")
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    // MARK: - Grouping

    @Test func rowsGroupUnderTodayYesterdayAndADate() throws {
        // 2026-09-29 15:00 in Toronto (UTC-4).
        let now = try date("2026-09-29T19:00:00Z")
        let rows = [
            row(at: try date("2026-09-29T18:00:00Z")),
            row(at: try date("2026-09-29T13:00:00Z")),
            row(at: try date("2026-09-28T20:00:00Z")),
            row(at: try date("2026-09-26T15:00:00Z")),
        ]
        let days = ActivityDay.group(rows, now: now, timeZone: toronto)
        #expect(days.map(\.label) == ["Today", "Yesterday", "Sep 26"])
        #expect(days.map(\.rows.count) == [2, 1, 1])
    }

    @Test func aDayBoundaryFollowsTheCourseTimezoneNotUTC() throws {
        // 2026-09-30 02:00 UTC is still 22:00 on Sep 29 in Toronto, so it is
        // "Today" when it is 23:30 there, even though UTC has moved on a day.
        let now = try date("2026-09-30T03:30:00Z")
        let late = row(at: try date("2026-09-30T02:00:00Z"))
        let earlier = row(at: try date("2026-09-29T20:00:00Z"))
        let days = ActivityDay.group([late, earlier], now: now, timeZone: toronto)
        #expect(days.count == 1)
        #expect(days.first?.label == "Today")
    }

    @Test func aRowJustAfterMidnightStartsANewDay() throws {
        let now = try date("2026-09-29T19:00:00Z")
        // 00:30 Sep 29 Toronto = 04:30 UTC; 23:30 Sep 28 Toronto = 03:30 UTC.
        let rows = [row(at: try date("2026-09-29T04:30:00Z")), row(at: try date("2026-09-29T03:30:00Z"))]
        let days = ActivityDay.group(rows, now: now, timeZone: toronto)
        #expect(days.map(\.label) == ["Today", "Yesterday"])
    }

    @Test func noRowsMakeNoDays() {
        #expect(ActivityDay.group([], now: Date(), timeZone: toronto).isEmpty)
    }

    // MARK: - Tiles

    @Test(arguments: [
        ("Content edit", "edit", "notebook", "#i-pencil"),
        ("Assignments", "status", "slides", "#i-eye"),
        ("Enrollment", "roster", "outline", "#i-list"),
        ("Users & roles", "roster", "outline", "#i-list"),
        ("Grading", "grade", "graded", "#i-calendar-check"),
        ("Submissions", "grade", "graded", "#i-calendar-check"),
        ("Courses", "other", "link", "#i-link"),
        ("Something new", "other", "link", "#i-link"),
    ])
    func categoriesMapToTiles(category: String, key: String, kind: String, icon: String) {
        let tile = ActivityCategoryTile.tile(forCategory: category)
        #expect(tile.key == key)
        #expect(tile.kind == kind)
        #expect(tile.icon == icon)
    }

    @Test func everyAuditCategoryMapsToATileThatExists() {
        // A new AuditCategory falls to the neutral tile rather than to nothing.
        for category in AuditCategory.allCases {
            let tile = ActivityCategoryTile.tile(forCategory: category.rawValue)
            #expect(!tile.kind.isEmpty && tile.icon.hasPrefix("#i-"))
        }
    }

    // MARK: - Page

    private func page(_ path: String, cookie: String, on app: Application) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    @Test func personSelectListsEveryoneThenStaff() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let ta = try await arInsertStudent(username: "act_ta", displayName: "Ada TA", on: app)
            try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta)
                .save(on: app.db)
            let pupil = try await arInsertStudent(username: "act_pupil", displayName: "Pupil", on: app)
            try await APICourseEnrollment(userID: try pupil.requireID(), courseID: courseID, role: .student)
                .save(on: app.db)

            let html = try await page("/instructor/activity", cookie: cookie, on: app)
            #expect(html.contains("<option value=\"\" selected>Everyone</option>"))
            #expect(html.contains("<option value=\"act_ta\">Ada TA</option>"))
            #expect(!html.contains("act_pupil"))
            #expect(!html.contains("filter-input"))
        }
    }

    @Test func theActorParameterRoundTripsIntoTheSelect() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let ta = try await arInsertStudent(username: "act_rt", displayName: "Round Trip", on: app)
            try await APICourseEnrollment(userID: try ta.requireID(), courseID: courseID, role: .ta)
                .save(on: app.db)

            let html = try await page("/instructor/activity?actor=act_rt", cookie: cookie, on: app)
            #expect(html.contains("<option value=\"act_rt\" selected>Round Trip</option>"))
            #expect(!html.contains("<option value=\"\" selected>"))
            #expect(html.contains("No activity matches that person."))
        }
    }

    @Test func aFormerStaffMemberInTheFilterStillGetsAnOption() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let html = try await page("/instructor/activity?actor=gone_person", cookie: cookie, on: app)
            #expect(html.contains("<option value=\"gone_person\" selected>gone_person</option>"))
        }
    }

    @Test func rowsRenderUnderADayHeadingWithATileAndTime() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let request = Request(application: app, on: app.eventLoopGroup.any())
            await AuditLogger.record(
                action: .enrollmentRoleChanged, targetType: .enrollment,
                targetID: UUID().uuidString,
                metadata: ["course_id": courseID.uuidString, "role": "ta"], on: request)

            let html = try await page("/instructor/activity", cookie: cookie, on: app)
            #expect(html.contains("Recent activity"))
            #expect(html.contains("<tr class=\"section-items-heading\">"))
            #expect(html.contains("<strong>Today</strong>"))
            #expect(html.contains("data-kind=\"outline\""))
            #expect(html.contains("role: ta"))
            #expect(html.contains("js-relative-time"))
        }
    }
}
