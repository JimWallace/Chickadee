// Tests/APITests/BrightSpace/BrightSpaceTabActionTests.swift
//
// The instructor BrightSpace tab's actions against a scripted D2L
// (`ScriptedLearnTab.swift`): the connection test, connecting a LEARN key,
// taking over as the course's sync identity, binding the org unit, the
// grade-item feed, auto-map and reconcile-now. Each test checks what the
// action stores, the flash that the tab shows next, and how a D2L failure
// reads. `BrightSpacePanelTests` covers the same routes with BrightSpace not
// configured; `BrightSpaceRoleFloorTests` covers who may use them.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) struct BrightSpaceTabActionTests {

    private static let whoami = ScriptedValenceReply(
        .ok, #"{"Identifier": "7", "FirstName": "Ada", "LastName": "Lovelace", "UniqueName": "alovelace"}"#)

    private static let gradeBook = ScriptedValenceReply(
        .ok,
        #"""
        [{"Id": 55, "Name": " lab one ", "MaxPoints": 10, "GradeType": "Numeric", "CanExceed": false},
         {"Id": 88, "Name": "Lab Three", "MaxPoints": 10, "GradeType": "Numeric", "CanExceed": false}]
        """#)

    private func auditEntries(_ action: AuditAction, on app: Application) async throws -> [APIAuditLogEntry] {
        try await APIAuditLogEntry.query(on: app.db).filter(\.$action == action.rawValue).all()
    }

    private func course(_ tab: ScriptedLearnTab, on app: Application) async throws -> APICourse {
        try #require(try await APICourse.find(tab.courseID, on: app.db))
    }

    // MARK: - Connection test

    @Test func theConnectionTestNamesTheLearnAccount() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, script: scriptedLearn(["/users/whoami": Self.whoami]))
            let response = try await tab.post("/instructor/brightspace/test", on: app)
            #expect(response.status == .ok)
            let result = try response.content.decode(BrightspaceTestResult.self)
            #expect(result.ok)
            #expect(result.message == "Connected as Ada Lovelace (alovelace).")
        }
    }

    @Test func aRefusedConnectionTestSaysWhoMustAct() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, script: scriptedLearn(["/users/whoami": ScriptedValenceReply(.unauthorized)]))
            let result = try await tab.post("/instructor/brightspace/test", on: app)
                .content.decode(BrightspaceTestResult.self)
            #expect(!result.ok)
            #expect(
                result.message
                    == "Couldn't connect to LEARN: LEARN refused the server's credentials. An admin can authorize again."
            )
        }
    }

    // MARK: - Connect

    @Test func connectNeedsBothFieldsAndAsksD2LNothing() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, connected: false, script: scriptedLearn(["/users/whoami": Self.whoami]))
            let response = try await tab.post(
                "/instructor/brightspace/connect", ["userID": "vu", "userKey": "   "], on: app)
            #expect(response.status == .seeOther)
            #expect(response.headers.first(name: .location) == "/instructor/brightspace")
            #expect(try await tab.page(on: app).contains("Both User ID and User Key are required."))
            #expect(tab.calls.isEmpty)
            #expect(try await BrightSpaceCredentialStore.load(userID: tab.instructorID, on: app.db) == nil)
        }
    }

    @Test func aKeyThatD2LRejectsIsNotStored() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, connected: false,
                script: scriptedLearn(["/users/whoami": ScriptedValenceReply(.forbidden, "Invalid token")]))
            let response = try await tab.post(
                "/instructor/brightspace/connect", ["userID": "vu", "userKey": "vk"], on: app)
            #expect(response.status == .seeOther)
            #expect(try await tab.page(on: app).contains("Could not verify those credentials against D2L"))
            #expect(try await BrightSpaceCredentialStore.load(userID: tab.instructorID, on: app.db) == nil)
            #expect(try await course(tab, on: app).brightspaceSyncUserID == nil)
            #expect(try await auditEntries(.brightspaceAccountConnected, on: app).isEmpty)
        }
    }

    @Test func connectingClaimsACourseThatHasNoSyncIdentity() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, connected: false, script: scriptedLearn(["/users/whoami": Self.whoami]))
            let response = try await tab.post(
                "/instructor/brightspace/connect", ["userID": " vu ", "userKey": " vk "], on: app)
            #expect(response.status == .seeOther)
            #expect(response.headers.first(name: .cacheControl) == "no-store")

            let stored = try #require(try await BrightSpaceCredentialStore.load(userID: tab.instructorID, on: app.db))
            #expect(stored.valenceUserID == "vu", "the pasted fields are trimmed")
            #expect(try await course(tab, on: app).brightspaceSyncUserID == tab.instructorID)
            #expect(
                try await tab.page(on: app).contains(
                    "Connected as Ada Lovelace (alovelace). This course now syncs grades as your LEARN account."))
            let entry = try #require(try await auditEntries(.brightspaceAccountConnected, on: app).first)
            #expect(entry.targetID == tab.instructorID.uuidString)
            #expect((entry.metadata ?? "").contains("Ada Lovelace (alovelace)"))
        }
    }

    @Test func connectingLeavesAnotherInstructorAsTheSyncIdentity() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, connected: false, script: scriptedLearn(["/users/whoami": Self.whoami]))
            let other = try await makeTestUser(on: app, username: "bs_co_instructor", role: "instructor")
            let otherID = try other.requireID()
            let linked = try await course(tab, on: app)
            linked.brightspaceSyncUserID = otherID
            try await linked.save(on: app.db)

            _ = try await tab.post("/instructor/brightspace/connect", ["userID": "vu", "userKey": "vk"], on: app)

            #expect(try await course(tab, on: app).brightspaceSyncUserID == otherID)
            #expect(try await BrightSpaceCredentialStore.load(userID: tab.instructorID, on: app.db) != nil)
            let page = try await tab.page(on: app)
            #expect(page.contains("Connected as Ada Lovelace (alovelace)."))
            #expect(!page.contains("This course now syncs grades as your LEARN account."))
        }
    }

    // MARK: - Use my identity

    @Test func useMyIdentityTakesOverTheCourseSyncIdentity() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, connected: false, script: scriptedLearn([:]))
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "vu", valenceUserKey: "vk", identityName: "Test Instructor",
                capturedByUserID: tab.instructorID, userID: tab.instructorID, on: app.db)
            let other = try await makeTestUser(on: app, username: "bs_previous_identity", role: "instructor")
            let linked = try await course(tab, on: app)
            linked.brightspaceSyncUserID = try other.requireID()
            try await linked.save(on: app.db)

            let response = try await tab.post("/instructor/brightspace/use-my-identity", on: app)
            #expect(response.status == .seeOther)
            #expect(try await course(tab, on: app).brightspaceSyncUserID == tab.instructorID)
            #expect(try await tab.page(on: app).contains("This course now syncs grades as your LEARN account."))
            let entry = try #require(try await auditEntries(.brightspaceSyncIdentitySet, on: app).first)
            #expect(entry.targetID == tab.courseID.uuidString)
            #expect(tab.calls.isEmpty, "designating reads nothing from D2L")
        }
    }

    // MARK: - Bind org unit

    struct BindCase: Sendable, CustomTestStringConvertible {
        let reply: ScriptedValenceReply
        let flash: String
        let storedName: String?
        var testDescription: String { "D2L answers \(reply.status.code)" }
    }

    static let bindCases: [BindCase] = [
        BindCase(
            reply: ScriptedValenceReply(.ok, #"{"Identifier": "900", "Name": "HLTH 230", "Code": "HLTH230-F26"}"#),
            flash: "Linked to HLTH 230 (org unit 900); this course syncs grades as your LEARN account.",
            storedName: "HLTH 230"),
        BindCase(
            reply: ScriptedValenceReply(.notFound),
            flash: "Saved org unit 900, but D2L reports no such org unit",
            storedName: nil),
        BindCase(
            reply: ScriptedValenceReply(.internalServerError),
            flash: "Saved org unit 900, but couldn't verify it in D2L:",
            storedName: nil),
    ]

    @Test(arguments: bindCases)
    func bindingSavesTheOrgUnitAndReportsWhatD2LSaid(_ bindCase: BindCase) async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, orgUnitID: nil, script: scriptedLearn(["/orgstructure/": bindCase.reply]))
            let response = try await tab.post("/instructor/brightspace/bind-org-unit", ["orgUnitID": " 900 "], on: app)
            #expect(response.status == .seeOther)

            let bound = try await course(tab, on: app)
            #expect(bound.brightspaceOrgUnitID == "900", "the binding is saved before it is verified")
            #expect(bound.brightspaceSyncUserID == tab.instructorID)
            #expect(bound.brightspaceOrgUnitName == bindCase.storedName)
            #expect(tab.calls.contains { $0.contains("/orgstructure/900") })
            #expect(try await tab.page(on: app).contains(bindCase.flash))
        }
    }

    // MARK: - Grade-item feed

    @Test func theGradeItemFeedListsTheBoundCourseGradeBook() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, script: scriptedLearn(["/grades/": Self.gradeBook]))
            let response = try await tab.get("/instructor/brightspace/grade-objects", on: app)
            #expect(response.status == .ok)
            let items = try response.content.decode([BrightSpaceGradeObject].self)
            #expect(items.map(\.id) == ["55", "88"])
            #expect(items.first?.gradeType == "Numeric")
            #expect(tab.calls.contains { $0.contains("/900/grades/") })
        }
    }

    @Test func aGradeBookThatD2LRefusesIsAnEmptyFeed() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, script: scriptedLearn(["/grades/": ScriptedValenceReply(.internalServerError)]))
            let response = try await tab.get("/instructor/brightspace/grade-objects", on: app)
            #expect(response.status == .ok)
            #expect(try response.content.decode([BrightSpaceGradeObject].self).isEmpty)
        }
    }

    // MARK: - Auto-map

    @Test func autoMapFillsOnlyEmptyMappingsByName() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, script: scriptedLearn(["/grades/": Self.gradeBook]))
            try await arInsertSetup(id: "setup_bs_map_one", on: app)
            try await arInsertSetup(id: "setup_bs_map_two", on: app)
            try await arInsertSetup(id: "setup_bs_map_three", on: app)
            let one = try await arInsertAssignment(
                testSetupID: "setup_bs_map_one", title: "Lab One", isOpen: true, on: app)
            let two = try await arInsertAssignment(
                testSetupID: "setup_bs_map_two", title: "Lab Two", isOpen: true, on: app)
            let three = try await arInsertAssignment(
                testSetupID: "setup_bs_map_three", title: "Lab Three", isOpen: true, on: app)
            three.brightspaceGradeObjectID = "77"
            try await three.save(on: app.db)

            #expect(try await tab.post("/instructor/brightspace/auto-map", on: app).status == .seeOther)
            #expect(try await tab.page(on: app).contains("Auto-mapped 1 assignment by name."))
            func mapping(_ assignment: APIAssignment) async throws -> String? {
                try await APIAssignment.find(try assignment.requireID(), on: app.db)?.brightspaceGradeObjectID
            }
            #expect(try await mapping(one) == "55", "the name match ignores case and spaces")
            #expect(try await mapping(two) == nil, "no grade item has this name")
            #expect(try await mapping(three) == "77", "an existing mapping is never replaced")
            let entry = try #require(try await auditEntries(.brightspaceAutoMapped, on: app).first)
            #expect(entry.targetID == tab.courseID.uuidString)

            _ = try await tab.post("/instructor/brightspace/auto-map", on: app)
            #expect(try await tab.page(on: app).contains("No new matches"))
        }
    }

    @Test func aGradeBookReadFailureIsExplainedAndMapsNothing() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, script: scriptedLearn(["/grades/": ScriptedValenceReply(.badGateway)]))
            #expect(try await tab.post("/instructor/brightspace/auto-map", on: app).status == .seeOther)
            #expect(
                try await tab.page(on: app).contains("read the LEARN grade book: LEARN reported an error."))
            #expect(try await auditEntries(.brightspaceAutoMapped, on: app).isEmpty)
        }
    }

    // MARK: - Reconcile now

    @Test func reconcileNowNeedsAConnectedIdentity() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(app, connected: false, script: scriptedLearn([:]))
            #expect(try await tab.post("/instructor/brightspace/reconcile-now", on: app).status == .seeOther)
            #expect(try await tab.page(on: app).contains("connected for this course yet."))
            #expect(tab.calls.isEmpty)
        }
    }

    @Test func reconcileNowStoresEachStudentReadinessAndCountsThem() async throws {
        try await withTestApp { app in
            let classlist = ScriptedValenceReply(
                .ok,
                #"{"Items": [{"Identifier": "501", "OrgDefinedId": "20123456", "Username": "someone_else"}], "PagingInfo": {"Bookmark": "", "HasMoreItems": false}}"#
            )
            let tab = try await openScriptedLearnTab(app, script: scriptedLearn(["/classlist/": classlist]))
            func enrol(_ username: String, studentID: String) async throws -> APICourseEnrollment {
                let student = try await makeTestStudent(on: app, username: username)
                student.studentID = studentID
                try await student.save(on: app.db)
                return try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: tab.courseID)
            }
            let onLearn = try await enrol("bs_rec_on", studentID: "20123456")
            let dropped = try await enrol("bs_rec_dropped", studentID: "20999999")

            #expect(try await tab.post("/instructor/brightspace/reconcile-now", on: app).status == .seeOther)
            #expect(
                try await tab.page(on: app).contains(
                    "Reconciled 2 students against LEARN: 1 confirmed, 1 unreachable."))
            func readiness(_ enrollment: APICourseEnrollment) async throws -> LearnSyncReadiness? {
                try await APICourseEnrollment.find(try enrollment.requireID(), on: app.db)?.learnSyncReadiness
            }
            #expect(try await readiness(onLearn) == .confirmed)
            #expect(try await readiness(dropped) == .unreachable)
        }
    }

    @Test func aClasslistFailureDuringReconcileIsExplained() async throws {
        try await withTestApp { app in
            let tab = try await openScriptedLearnTab(
                app, script: scriptedLearn(["/classlist/": ScriptedValenceReply(.serviceUnavailable)]))
            #expect(try await tab.post("/instructor/brightspace/reconcile-now", on: app).status == .seeOther)
            #expect(
                try await tab.page(on: app).contains("reconcile against LEARN: LEARN reported an error."))
        }
    }

    // MARK: - No active course

    @Test(arguments: [
        "/instructor/brightspace/connect", "/instructor/brightspace/use-my-identity",
        "/instructor/brightspace/sync-now", "/instructor/brightspace/reconcile-now",
    ])
    func anAdminWithNoActiveCourseIsSentBackWithAReason(_ path: String) async throws {
        try await withTestApp { app in
            let cookie = try await loginAsAdmin("bs_courseless_admin", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
            let response = try await app.asyncSendRequest(.POST, path) { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                try req.content.encode(["_csrf": csrf, "userID": "vu", "userKey": "vk"], as: .urlEncodedForm)
            }
            #expect(response.status == .seeOther)
            #expect(response.headers.first(name: .location) == "/instructor/brightspace")
            let learnEntries = try await APIAuditLogEntry.query(on: app.db).all()
                .filter { $0.action.hasPrefix("brightspace.") }
            #expect(learnEntries.isEmpty, "nothing was changed")
        }
    }
}
