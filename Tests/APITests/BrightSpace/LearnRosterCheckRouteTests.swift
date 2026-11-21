// Tests/APITests/BrightSpace/LearnRosterCheckRouteTests.swift
//
// GET /instructor/students/learn-check through the Valence classlist, against
// a scripted D2L (`ScriptedLearnTab.swift`). The check flags an enrolled
// student whose student ID LEARN does not list, cannot place a student with
// no student ID, and never flags course staff. A pending pre-enrolment that
// LEARN does not list is flagged too. When the check cannot run, the payload
// says why: no active course, no LEARN connection, no org unit, or a failed
// classlist read. `LTIRosterCheckTests` covers the same route through the
// LMS membership service.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) struct LearnRosterCheckRouteTests {

    private static let path = "/instructor/students/learn-check"

    private func check(_ tab: ScriptedLearnTab, on app: Application) async throws -> LearnRosterCheckResult {
        let response = try await tab.get(Self.path, on: app)
        #expect(response.status == .ok)
        return try response.content.decode(LearnRosterCheckResult.self)
    }

    private func enrol(
        _ username: String, studentID: String?, role: CourseRole = .student, in courseID: UUID, on app: Application
    ) async throws -> UUID {
        let user = try await makeTestUser(on: app, username: username)
        user.studentID = studentID
        try await user.save(on: app.db)
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: role).save(on: app.db)
        return userID
    }

    @Test func theCheckFlagsWhoLearnDoesNotListAndNeverFlagsStaff() async throws {
        try await withTestApp { app in
            let classlist = ScriptedValenceReply(
                .ok,
                #"""
                {"Items": [
                  {"Identifier": "501", "OrgDefinedId": "20111111", "Username": "x_on_by_id"},
                  {"Identifier": "502", "OrgDefinedId": null, "Username": "lc_on_by_name"},
                  {"Identifier": "503", "OrgDefinedId": null, "Username": "lc_pending_on"}
                ], "PagingInfo": {"Bookmark": "", "HasMoreItems": false}}
                """#)
            let tab = try await openScriptedLearnTab(app, script: scriptedLearn(["/classlist/": classlist]))
            let courseID = tab.courseID
            let onByID = try await enrol("lc_on_by_id", studentID: "20111111", in: courseID, on: app)
            let onByName = try await enrol("lc_on_by_name", studentID: nil, in: courseID, on: app)
            let dropped = try await enrol("lc_dropped", studentID: "20999999", in: courseID, on: app)
            let noStudentID = try await enrol("lc_no_number", studentID: nil, in: courseID, on: app)
            let ta = try await enrol("lc_ta", studentID: "20888888", role: .ta, in: courseID, on: app)
            let pendingOn = APIPreEnrollment(courseID: courseID, username: "lc_pending_on")
            try await pendingOn.save(on: app.db)
            let pendingGone = APIPreEnrollment(courseID: courseID, username: "lc_pending_gone")
            try await pendingGone.save(on: app.db)

            let result = try await check(tab, on: app)

            #expect(result.ok)
            #expect(result.configured)
            #expect(result.courseLinked)
            #expect(result.learnCount == 3)
            #expect(result.checkedCount == 6, "four students and two pending rows; staff are not checked")
            #expect(Set(result.notOnLearn) == [dropped.uuidString, try pendingGone.requireID().uuidString])
            #expect(result.unverifiable == [noStudentID.uuidString])
            let flagged = Set(result.notOnLearn + result.unverifiable)
            for listed in [onByID, onByName, ta] {
                #expect(!flagged.contains(listed.uuidString))
            }
            #expect(!flagged.contains(try pendingOn.requireID().uuidString))
            #expect(
                result.message
                    == "Checked 6 against 3 on LEARN — 2 not registered on LEARN, 1 couldn't be matched (no student ID)."
            )
            #expect(tab.calls.contains { $0.contains("/900/classlist/paged/") })
        }
    }

    @Test func aRosterThatLearnListsInFullFlagsNothing() async throws {
        try await withTestApp { app in
            let classlist = ScriptedValenceReply(
                .ok,
                #"{"Items": [{"Identifier": "501", "OrgDefinedId": "20111111", "Username": "lc_all"}], "PagingInfo": {"Bookmark": "", "HasMoreItems": false}}"#
            )
            let tab = try await openScriptedLearnTab(app, script: scriptedLearn(["/classlist/": classlist]))
            _ = try await enrol("lc_all", studentID: "20111111", in: tab.courseID, on: app)

            let result = try await check(tab, on: app)
            #expect(result.ok)
            #expect(result.notOnLearn.isEmpty)
            #expect(result.unverifiable.isEmpty)
            #expect(result.message == "Checked 1 against 1 on LEARN — 0 not registered on LEARN.")
        }
    }

    // MARK: - When the check cannot run

    @Test func aCourseWithNoLearnIdentityIsNotConfigured() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, connected: false, script: scriptedLearn([:]))
            let result = try await check(tab, on: app)
            #expect(!result.ok)
            #expect(!result.configured)
            #expect(result.courseLinked)
            #expect(result.message.contains("connected for this course yet."))
            #expect(tab.calls.isEmpty)
        }
    }

    @Test func aCourseWithNoOrgUnitIsNotLinked() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, orgUnitID: "", script: scriptedLearn([:]))
            let result = try await check(tab, on: app)
            #expect(!result.ok)
            #expect(result.configured)
            #expect(!result.courseLinked)
            #expect(result.message.contains("linked to a LEARN org unit"))
            #expect(tab.calls.isEmpty)
        }
    }

    @Test func aFailedClasslistReadFlagsNobody() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, script: scriptedLearn(["/classlist/": ScriptedValenceReply(.unauthorized)]))
            _ = try await enrol("lc_unread", studentID: "20111111", in: tab.courseID, on: app)

            let result = try await check(tab, on: app)
            #expect(!result.ok)
            #expect(result.notOnLearn.isEmpty)
            #expect(result.checkedCount == 0)
            #expect(
                result.message
                    == "Couldn't fetch the LEARN classlist: LEARN refused the server's credentials. An admin can authorize again."
            )
        }
    }

    @Test func anAdminWithNoActiveCourseIsToldSo() async throws {
        try await withTestApp { app in
            let cookie = try await loginAsAdmin("lc_courseless_admin", on: app)
            let response = try await getResponse(Self.path, cookie: cookie, on: app)
            #expect(response.status == .ok)
            let result = try response.content.decode(LearnRosterCheckResult.self)
            #expect(!result.ok)
            #expect(result.message == "No active course selected.")
        }
    }
}
