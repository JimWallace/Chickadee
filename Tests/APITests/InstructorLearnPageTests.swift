// Tests/APITests/InstructorLearnPageTests.swift
//
// The instructor LEARN tab after the redesign: with a deployment service account
// the per-instructor identity controls and the grades CSV link are hidden (not
// removed), without one they return, and the page shows the facts, grade items
// and roster in the shared row shape.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorLearnPageTests {

    private let appCredentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)

    private func configure(_ app: Application, serviceAccount: Bool) {
        app.brightSpaceAppCredentials = appCredentials
        if serviceAccount {
            app.brightSpaceClient = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: appCredentials, userID: "svc", userKey: "svc-key"))
        }
    }

    private func learnPage(_ app: Application, cookie: String) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, "/instructor/brightspace",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    // MARK: - The service-account flag

    @Test func theFlagFollowsTheDeploymentWideClient() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: false)
            #expect(!app.brightSpaceUsesServiceAccount)
            configure(app, serviceAccount: true)
            #expect(app.brightSpaceUsesServiceAccount)
        }
    }

    @Test func withAServiceAccountThePerInstructorControlsAreHidden() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: true)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
            // Even an instructor who HAS a connected account sees none of it.
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "vu", valenceUserKey: "vk", identityName: "Test Instructor (ti)",
                capturedByUserID: instructor.id, userID: instructor.id, on: app.db)

            let html = try await learnPage(app, cookie: cookie)
            #expect(!html.contains("Your LEARN account"))
            #expect(!html.contains("This course pushes grades as"))
            #expect(!html.contains("/instructor/brightspace/connect"))
            #expect(!html.contains("/instructor/brightspace/use-my-identity"))
            #expect(!html.contains("/instructor/brightspace/disconnect"))
            #expect(!html.contains("Export Grades CSV"))
            #expect(!html.contains("/instructor/grades.csv"))
            #expect(html.contains("Service account"))
            #expect(html.contains("Managed by Chickadee admins"))
            #expect(html.contains("<span class=\"tier tier-open\">Connected</span>"))
            // The facts card still offers the org-unit change and the test.
            #expect(html.contains("/instructor/brightspace/bind-org-unit"))
            #expect(html.contains("Test connection"))
        }
    }

    @Test func withoutAServiceAccountTheControlsComeBack() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: false)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            let html = try await learnPage(app, cookie: cookie)
            #expect(html.contains("Your LEARN account is not connected"))
            #expect(html.contains("/instructor/brightspace/connect"))
            #expect(html.contains("Export Grades CSV"))
            #expect(!html.contains("Service account"))
        }
    }

    @Test func theHiddenRoutesStillExist() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: true)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/brightspace/disconnect",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    // Hidden from the page, still registered: a redirect, not a 404.
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/brightspace")
                })
            try await app.asyncTest(
                .GET, "/instructor/grades.csv",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })
        }
    }

    @Test func aDisconnectedDesignatedIdentityPausesTheSync() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: true)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.brightspaceSyncUserID = instructor.id
            try await course.save(on: app.db)

            let html = try await learnPage(app, cookie: cookie)
            #expect(html.contains("<span class=\"tier tier-danger\">Paused</span>"))
            #expect(html.contains("Grade sync is paused"))
            #expect(html.contains("Ask a Chickadee admin."))
        }
    }

    // MARK: - Rows

    @Test func gradeItemRowsShowMappingStateAndTheFailureText() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: true)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_learn_a", on: app)
            let mapped = try await arInsertAssignment(
                testSetupID: "setup_learn_a", title: "Mapped Lab", isOpen: true, on: app)
            mapped.brightspaceGradeObjectID = "12345"
            try await mapped.save(on: app.db)
            try await arInsertSetup(id: "setup_learn_b", on: app)
            _ = try await arInsertAssignment(
                testSetupID: "setup_learn_b", title: "Loose Lab", isOpen: true, on: app)

            let html = try await learnPage(app, cookie: cookie)
            #expect(html.contains("class=\"state-select\" data-state=\"mapped\""))
            #expect(html.contains("class=\"state-select\" data-state=\"unmapped\""))
            #expect(html.contains("Not synced yet"))
            #expect(html.contains("js-bs-grade-id-hidden"))
            #expect(html.contains("Auto-map by name"))
        }
    }

    @Test func syncDetailTextPrefersTheFailureOverTheTime() {
        #expect(
            InstructorDashboardRoutes.syncDetailText(status: "error", detail: "403 from D2L", at: "Sep 3")
                == "403 from D2L")
        #expect(
            InstructorDashboardRoutes.syncDetailText(status: "error", detail: nil, at: "Sep 3")
                == "The last push failed")
        #expect(
            InstructorDashboardRoutes.syncDetailText(status: "success", detail: nil, at: "Sep 3")
                == "Last synced Sep 3")
        #expect(
            InstructorDashboardRoutes.syncDetailText(status: "none", detail: nil, at: nil)
                == "Not synced yet")
    }

    @Test func pushesAsNamesTheAccountThatWillActuallyPush() {
        let fallback = (name: Optional("Deployment default account"), connected: true, isMe: false)
        #expect(
            InstructorDashboardRoutes.pushesAs(identity: fallback, usesServiceAccount: true).text
                == "Service account")
        let designated = (name: Optional("Prof Lee (plee)"), connected: true, isMe: false)
        #expect(
            InstructorDashboardRoutes.pushesAs(identity: designated, usesServiceAccount: true).text
                == "Prof Lee (plee)")
        let nobody = (name: String?.none, connected: false, isMe: false)
        #expect(
            InstructorDashboardRoutes.pushesAs(identity: nobody, usesServiceAccount: false).text
                == "Not connected")
    }

    @Test func unreachableStudentsGetTheirOwnAvatarAndARemoveMenu() async throws {
        try await withAssignmentRoutesApp { app in
            configure(app, serviceAccount: true)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.brightspaceOrgUnitID = "999"
            try await course.save(on: app.db)
            let student = try await arInsertStudent(
                username: "learn_unreach", displayName: "Una Reachable", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == student.requireID()).first())
            enrollment.learnSyncReadiness = .unreachable
            enrollment.brightspaceSyncDetail = "Not on the LEARN classlist."
            enrollment.brightspaceCheckedAt = Date()
            try await enrollment.save(on: app.db)
            let cookie = try await arLoginAsInstructor(on: app)

            let html = try await learnPage(app, cookie: cookie)
            #expect(html.contains("Una Reachable"))
            #expect(html.contains("class=\"avatar avatar-md\""))
            #expect(html.contains("1 student can"))
            #expect(html.contains("receive grades · checked"))
            #expect(html.contains("aria-label=\"More actions for Una Reachable\""))
            #expect(html.contains("Remove from course"))
            #expect(html.contains("Reconcile now"))
        }
    }
}
