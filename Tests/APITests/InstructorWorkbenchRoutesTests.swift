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
                    // `view=` is always explicit: the server defaults staff to
                    // the template on a notebook with placeholders, so an
                    // omitted `view=` would make the Assignment tab mean
                    // different things on different assignments.
                    #expect(html.contains("file=assignment&amp;view=personalized&amp;embedded=1"))
                    // `validationStatus == "passed"` means a reference solution
                    // exists, so the solution tab is offered.
                    // The destination table rides a data-attribute, so Leaf
                    // HTML-escapes it: quotes become &quot; and & becomes &amp;.
                    #expect(html.contains("solution:personalized"))
                    #expect(html.contains("file=solution&amp;view=personalized&amp;embedded=1"))
                    // One notebook document, not one per destination: the Files
                    // table repoints a single iframe.
                    #expect(html.contains("id=\"wb-notebook\""))
                    // The chrome the review asked for: one Save, and none of
                    // the controls the left pane already provides.
                    #expect(html.contains("id=\"wb-save\""))
                    #expect(!html.contains("wb-tab-solution"))
                    #expect(!html.contains("wb-collapse-edit"))
                    #expect(!html.contains("Full-width editor"))
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
                    // The Files table's Edit buttons are what open a notebook
                    // in the other pane, so they must carry the marker
                    // embedded-pane.js keys on.
                    #expect(html.contains("data-wb-file=\"assignment\""))
                    // Only the assignment marker: this fixture has no reference
                    // solution, so that row renders "Create solution" instead of
                    // an Edit button.  The solution marker is covered by the
                    // browser check, which seeds one.
                    // One Save lives in the shell; a second here would be the
                    // same action twice.  `liveEdit` is what stops that Save
                    // closing the assignment.
                    #expect(!html.contains("Save &amp; Validate"))
                    #expect(html.contains("name=\"liveEdit\""))
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
                    // Standalone keeps its own Save, and does NOT send
                    // `liveEdit` — so it still closes on save, as it always has.
                    #expect(html.contains("Save &amp; Validate"))
                    #expect(!html.contains("name=\"liveEdit\""))
                })
        }
    }

    // MARK: - close-on-save, and the workbench's opt-out
    //
    // The pair below governs student-facing state, so it is pinned in both
    // directions rather than only the new one.
    //
    // The standalone edit page has always closed an assignment on save, so
    // re-validation gates re-opening.  The workbench must not: it is a
    // live-edit surface (`PUT /suite`, `PUT /families` and
    // `POST /notebook/save` all write without touching visibility), and
    // closing there would pull a lab out from under the students sitting in
    // it.  The whole difference is one form field, which is exactly the kind
    // of thing that regresses without anyone noticing.
    //
    // These need the full multipart body — the handler returns early without a
    // notebook, a solution and a non-empty suite, long before it reaches the
    // visibility line.

    private func saveBody(csrf: String, boundary: String, liveEdit: Bool) -> ByteBuffer {
        let notebook = """
            {"cells":[{"cell_type":"code","source":["x = 1\\n"],"metadata":{},"outputs":[],\
            "execution_count":null}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """
        var fields: [(String, String)] = [
            ("_csrf", csrf),
            ("assignmentName", "Visibility Probe"),
            ("dueAt", ""),
        ]
        if liveEdit { fields.append(("liveEdit", "1")) }
        return arMultipartBody(
            boundary: boundary,
            fields: fields,
            files: [
                ("assignmentNotebookFile", "assignment.ipynb", "application/json", Data(notebook.utf8)),
                ("solutionNotebookFile", "solution.ipynb", "application/json", Data(notebook.utf8)),
            ]
        )
    }

    private func visibilityAfterSave(
        liveEdit: Bool, setupID: String, on app: Application
    ) async throws
        -> AssignmentVisibility
    {
        let cookie = try await arLoginAsInstructor(on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await arInsertSetup(
            id: setupID,
            manifest: """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],\
                "timeLimitSeconds":10,"makefile":null}
                """,
            on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: setupID, title: "Visibility Probe", isOpen: true, on: app)
        assignment.visibility = .open
        try await assignment.save(on: app.db)

        let boundary = "wbboundary\(setupID)"
        try await app.asyncTest(
            .POST, "/instructor/\(assignment.publicID)/edit/save",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = .init(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = saveBody(csrf: csrf, boundary: boundary, liveEdit: liveEdit)
            },
            afterResponse: { _ in })

        let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
        return reloaded.visibility
    }

    @Test func saveWithoutLiveEditClosesTheAssignment() async throws {
        try await withAssignmentRoutesApp { app in
            let visibility = try await visibilityAfterSave(
                liveEdit: false, setupID: "setup_vis_closed", on: app)
            #expect(visibility == .closed, "The standalone edit page must keep close-on-save")
        }
    }

    @Test func saveWithLiveEditLeavesTheAssignmentOpen() async throws {
        try await withAssignmentRoutesApp { app in
            let visibility = try await visibilityAfterSave(
                liveEdit: true, setupID: "setup_vis_open", on: app)
            #expect(
                visibility == .open,
                "A workbench save must not close a lab that students are working in")
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
