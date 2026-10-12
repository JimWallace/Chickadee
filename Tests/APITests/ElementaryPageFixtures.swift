// Tests/APITests/ElementaryPageFixtures.swift
//
// Every Elementary page, rendered with fixture data that reaches each of its
// branches. ElementaryPageGuardTests runs the UI rules over these renders, and
// fails when a page type under Sources/APIServer/Views/Pages/ has no entry
// here, so a new page cannot ship unguarded.

import Core
import Foundation

@testable import APIServer

struct ElementaryPageFixture {
    /// The page's Swift type name, as declared in `Views/Pages/`.
    let typeName: String
    /// The page's archetype, or the nearest one when the page predates the
    /// rulebook and fits none exactly.
    let archetype: PageArchetypeTests.Archetype
    /// One render per branch worth checking.
    let renders: [String]
    /// True for the page an archetype names as its exemplar in
    /// docs/ui-design.md. Only exemplars are held to the archetype's rules:
    /// "It checks the exemplars and nothing else: no page fails for not being
    /// one."
    var isExemplar = false
}

enum ElementaryPageFixtures {

    static var all: [ElementaryPageFixture] {
        [adminUserPage, loginPage, registerPage] + historyPages + mcpLtiPages + studentPages
            + adminIntegrationPages + adminCorePages + adminDataPages
            + instructorIntegrationPages + instructorOverviewPages + instructorPeoplePages + leaderboardPages
    }

    // MARK: - Shared values

    static func page(currentUser: CurrentUserContext? = nil) -> PageRequestContext {
        PageRequestContext(
            currentUser: currentUser,
            csrfToken: "fixture-token",
            appVersion: "0.0.0",
            sessionIdleTimeoutSeconds: 1800,
            sessionIdleWarningSeconds: 120,
            iconSprite: ""
        )
    }

    /// An admin who teaches two courses, so the nav renders the Instructor
    /// menu and the course tab strip.
    static var signedInAdmin: CurrentUserContext {
        let user = APIUser(username: "fixture-admin", passwordHash: "", role: UserRole.admin.rawValue)
        let courses = [
            CourseContext(
                id: "c1", code: "CS135", name: "Design", isActive: true, role: .instructor,
                termLabel: "Fall 2026", termShortLabel: "F26", urlKey: "CS135-F26"),
            CourseContext(
                id: "c2", code: "CS136", name: "Algorithms", isActive: false, role: .ta,
                termLabel: nil, termShortLabel: nil, urlKey: "CS136"),
        ]
        return CurrentUserContext(user: user, activeCourse: courses[0], enrolledCourses: courses)
    }

    // MARK: - Pages

    static var loginPage: ElementaryPageFixture {
        func render(error: String?, loggedOut: Bool, local: Bool, sso: Bool) -> String {
            LoginPage(
                page: page(), error: error, loggedOut: loggedOut, showLocalLogin: local, showRegisterLink: local,
                showSSOLogin: sso
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "LoginPage",
            archetype: .authBox,
            renders: [
                render(error: nil, loggedOut: true, local: true, sso: true),
                render(error: "invalid", loggedOut: false, local: true, sso: false),
                render(error: "sso_failed", loggedOut: false, local: false, sso: true),
            ]
        )
    }

    static var registerPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "RegisterPage",
            archetype: .authBox,
            renders: [
                RegisterPage(page: page(), error: nil).render(),
                RegisterPage(page: page(), error: "taken").render(),
            ],
            isExemplar: true
        )
    }

    static var adminUserPage: ElementaryPageFixture {
        let fall = AdminCourseRef(id: "c1", code: "CS135", name: "Design", termLabel: "Fall 2026")
        let untermed = AdminCourseRef(id: "c2", code: "CS136", name: "Algorithms", termLabel: nil)
        func render(
            _ currentUser: CurrentUserContext?, enrolled: [AdminCourseRef], available: [AdminCourseRef],
            flash: FlashMessages = FlashMessages()
        ) -> String {
            AdminUserPage(
                page: page(currentUser: currentUser), flash: flash, targetUserID: "u1", displayName: "Ada",
                username: "ada", role: "user", enrolledCourses: enrolled, availableCourses: available
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminUserPage",
            archetype: .titlebarPage,
            renders: [
                render(nil, enrolled: [], available: []),
                render(signedInAdmin, enrolled: [fall], available: [untermed]),
                render(
                    signedInAdmin, enrolled: [fall, untermed], available: [],
                    flash: FlashMessages(error: AdminEnrollError.invalidCourse.message)),
            ],
            isExemplar: true
        )
    }
}
