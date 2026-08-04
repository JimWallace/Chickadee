// Tests/APITests/InstructorWorkbenchRoutesTests.swift
//
// The assignment workbench: a shell page that composes the instructor edit page
// and the notebook editor as two same-origin iframe panes.
//
// What these tests are really pinning is that the shell *reuses* rather than
// reimplements.  The left pane is the ordinary edit page rendered from the same
// context builder, so the risk is not that it looks wrong — it is that it
// silently stops rendering (the LeafKit multi-`#extend` failure this page's
// design exists to avoid) or that the chrome suppression leaks into the
// standalone page.
//
// The isolation headers these routes also need live in COEPMiddlewareTests.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorWorkbenchRoutesTests {

    // MARK: - Shell

    @Test func workbenchShellReferencesBothPanes() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb1", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb1", title: "Workbench Lab", isOpen: false,
                validationStatus: "passed", on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("/instructor/\(assignment.publicID)/workbench/panel"))
                    #expect(html.contains("/testsetups/setup_wb1/notebook?file=assignment&amp;embedded=1"))
                    // `validationStatus == "passed"` means a reference solution
                    // exists, so the solution tab is offered.
                    #expect(html.contains("/testsetups/setup_wb1/notebook?file=solution&amp;embedded=1"))
                    #expect(html.contains("Workbench Lab"))
                })
        }
    }

    /// No solution yet → the tab is *absent*, not disabled, mirroring how the
    /// edit page omits `solutionNotebookEditURL` entirely.
    @Test func workbenchOmitsSolutionTabWhenThereIsNoSolution() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb2", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb2", title: "No Solution Yet", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("file=assignment"))
                    #expect(!html.contains("file=solution"))
                    #expect(!html.contains("wb-tab-solution"))
                })
        }
    }

    // MARK: - Left pane

    /// The pane must render the *whole* edit page — this is the assertion that
    /// would fail if `assignment-edit.leaf` ever hit the LeafKit extend bug, and
    /// the reason the workbench composes by iframe instead of merging templates.
    @Test func panelRendersTheEditPageWithoutSiteChrome() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb3", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb3", title: "Panel Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench/panel",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // The real editor is present …
                    #expect(html.contains("suite-sections"))
                    #expect(html.contains("global-inputs-block"))
                    #expect(html.contains("notebook-files-table"))
                    #expect(html.contains("Panel Lab"))
                    // … the site chrome is not …
                    #expect(!html.contains("<nav class=\"nav\""))
                    #expect(!html.contains("skip-link"))
                    #expect(!html.contains("/idle-logout.js"))
                    #expect(html.contains("/embedded-activity.js"))
                    // … and the pane does not link to the surface containing it.
                    #expect(!html.contains("/workbench\""))
                })
        }
    }

    /// The standalone edit page is the control: same template, chrome intact,
    /// plus the entry point into the workbench.
    @Test func standaloneEditPageKeepsChromeAndOffersTheWorkbench() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb4", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb4", title: "Standalone Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("<nav class=\"nav\""))
                    #expect(html.contains("/idle-logout.js"))
                    #expect(!html.contains("/embedded-activity.js"))
                    #expect(html.contains("/instructor/\(assignment.publicID)/workbench"))
                })
        }
    }

    // MARK: - Access control

    /// Both routes sit behind the same per-course staff gate as the rest of the
    /// authoring surface.  A student in the course is not staff, and the
    /// workbench must not become a way around that.
    @Test func studentsCannotReachTheWorkbench() async throws {
        try await withAssignmentRoutesApp { app in
            let studentCookie = try await arLoginAsStudent(on: app)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
            try await arEnrollStudentInTestCourse(student, on: app)

            try await arInsertSetup(id: "setup_wb5", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb5", title: "Gated Lab", isOpen: true, on: app)

            for path in [
                "/instructor/\(assignment.publicID)/workbench",
                "/instructor/\(assignment.publicID)/workbench/panel",
            ] {
                try await app.asyncTest(
                    .GET, path,
                    beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                    afterResponse: { res in
                        #expect(
                            res.status != .ok,
                            "A student reached \(path) — the staff gate is not applied")
                    })
            }
        }
    }

    @Test func unauthenticatedVisitorsAreNotServedTheWorkbench() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb6", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb6", title: "Anon Lab", isOpen: false, on: app)
            _ = cookie

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                afterResponse: { res in
                    #expect(res.status != .ok)
                })
        }
    }

    @Test func unknownAssignmentIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/nosuch/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }
}
