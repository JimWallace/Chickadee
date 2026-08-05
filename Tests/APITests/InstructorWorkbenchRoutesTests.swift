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
                    // `view=` is always explicit: the server defaults staff to
                    // the template on a notebook with placeholders, so an
                    // omitted `view=` would make the Assignment tab mean
                    // different things on different assignments.
                    //
                    // #1266: these now address the *workbench* route, not the
                    // notebook page — switching notebooks is a navigation of
                    // this page rather than a repointed iframe.
                    #expect(html.contains("file=assignment&amp;view=personalized"))
                    #expect(!html.contains("embedded=1"))
                    // `validationStatus == "passed"` means a reference solution
                    // exists, so the solution tab is offered.
                    #expect(html.contains("solution:personalized"))
                    #expect(html.contains("file=solution&amp;view=personalized"))
                    // The chrome: one Save, and none of the controls the edit
                    // half already provides.
                    #expect(html.contains("id=\"wb-save\""))
                    #expect(!html.contains("wb-tab-solution"))
                    #expect(!html.contains("wb-collapse-edit"))
                    #expect(!html.contains("Full-width editor"))
                    #expect(html.contains("Workbench Lab"))
                })
        }
    }

    /// #1266's central claim: the workbench is **one document**.
    ///
    /// The edit form and the notebook body are both present, and the only
    /// `<iframe>` left is the JupyterLite editor itself. The two wrapper frames
    /// (`wb-edit-frame`, `wb-notebook`) are what made a write in the left pane
    /// able to navigate a pane out from under the author.
    @Test func workbenchIsOneDocumentWithOnlyTheEditorIframe() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let setup = try await arInsertSetup(id: "setup_wb_merged", on: app)
            _ = try await arAttachStarterNotebook(
                to: setup,
                bytes: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8),
                on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb_merged", title: "Merged Lab", isOpen: false,
                validationStatus: "passed", on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string

                    // The edit half, inline — not behind an iframe.
                    #expect(html.contains("suite-sections"))
                    #expect(html.contains("notebook-files-table"))
                    // The notebook half, inline, with the editor iframe.
                    #expect(html.contains("id=\"jl-frame\""))

                    // The wrapper frames are gone.
                    #expect(!html.contains("id=\"wb-edit-frame\""))
                    #expect(!html.contains("id=\"wb-notebook\""))

                    // Exactly one iframe in the whole document, and it is the
                    // editor. Counted rather than name-checked: a second frame
                    // reintroduced under any id is the regression.
                    let iframeCount = html.components(separatedBy: "<iframe").count - 1
                    #expect(iframeCount == 1, "expected exactly one iframe, found \(iframeCount)")

                    // The cross-frame layer is deleted, not merely unused.
                    #expect(!html.contains("/embedded-pane.js"))
                    #expect(!html.contains("/embedded-activity.js"))
                    // ...and the merged page keeps the in-place form handler,
                    // which is what stops a write navigating the kernel away.
                    #expect(html.contains("/inplace-forms.js"))
                    #expect(html.contains("data-ck-inplace"))
                    // A normal page again: the idle watchdog needs no forwarder.
                    #expect(html.contains("/idle-logout.js"))
                })
        }
    }

    /// An assignment with no notebook on disk still renders an editable page.
    ///
    /// Inlining the notebook made its absence able to fail the whole route;
    /// before the merge it failed inside an iframe and left the edit half
    /// usable. The degraded pane keeps that property.
    @Test func workbenchWithoutANotebookStillRendersTheEditHalf() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb_nonb", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb_nonb", title: "No Notebook Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("No notebook yet"))
                    // The edit half is fully present — uploading a starter is
                    // one of the things it is for.
                    #expect(html.contains("notebook-files-table"))
                    #expect(html.contains("No Notebook Lab"))
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

    // MARK: - Edit half

    /// The merged page must carry the *whole* edit page, not a reduced copy of
    /// it. Retargeted from the deleted `/workbench/panel` route in #1266: the
    /// edit half is now inline, so this asserts against the workbench URL.
    @Test func workbenchRendersTheWholeEditPage() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb3", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb3", title: "Panel Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // The real editor is present …
                    #expect(html.contains("suite-sections"))
                    #expect(html.contains("global-inputs-block"))
                    #expect(html.contains("notebook-files-table"))
                    #expect(html.contains("Panel Lab"))
                    // … and the page carries the ordinary site chrome once,
                    // at the top level.  It used to be suppressed here because
                    // this markup was an iframe's document sitting under the
                    // shell's own nav; merged, there is one document and one
                    // nav, so the skip link is correct rather than duplicated.
                    #expect(html.contains("skip-link"))
                    // The Files table's Edit buttons are what choose which
                    // notebook is open, so they must keep their marker.
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
                    // Every write on this page answers with a redirect.  In
                    // one document, following it would navigate away from the
                    // live kernel — so each such form carries the in-place
                    // marker and the handler fetches it instead.
                    #expect(html.contains("/inplace-forms.js"))
                    #expect(html.contains("data-ck-inplace"))
                })
        }
    }

    /// Each navigating write is marked individually, so this counts them rather
    /// than asserting the attribute appears at all.  A form that loses its
    /// marker keeps working on the standalone page and silently goes back to
    /// navigating the pane — a regression with no error and no failing test
    /// unless the count is pinned.
    @Test func everyNavigatingWriteFormIsMarkedForInPlaceSubmission() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(
                id: "setup_wb7",
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[],\
                    "sections":[{"id":"sec1","name":"Question 1","variables":[],"expressions":[]}],\
                    "timeLimitSeconds":10,"makefile":null}
                    """,
                on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb7", title: "Marked Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Compare the marked set to the expected set rather than
                    // counting occurrences of the attribute: counting passes if
                    // the marker lands on the wrong form, and it also matches
                    // the word where it appears in a template comment.
                    let base = "/instructor/\(assignment.publicID)"
                    let expected: Set<String> = [
                        "\(base)/edit/save",
                        "\(base)/create-solution",
                        "\(base)/secret-reveal",
                        "\(base)/suite-sections",
                        "\(base)/suite-sections/sec1/rename",
                    ]
                    #expect(
                        markedFormActions(in: html) == expected,
                        "a write form lost its in-place marker, or one gained it")
                })
        }
    }

    /// The `action` of every `<form>` in `html` that carries `data-ck-inplace`.
    /// Deliberately parses the open tags rather than searching the whole
    /// document, so prose in a template comment cannot be mistaken for markup.
    private func markedFormActions(in html: String) -> Set<String> {
        var actions: Set<String> = []
        for chunk in html.components(separatedBy: "<form ").dropFirst() {
            guard let end = chunk.firstIndex(of: ">") else { continue }
            let tag = String(chunk[chunk.startIndex..<end])
            guard tag.contains("data-ck-inplace") else { continue }
            guard let actionStart = tag.range(of: "action=\"") else { continue }
            let rest = tag[actionStart.upperBound...]
            guard let quote = rest.firstIndex(of: "\"") else { continue }
            actions.insert(String(rest[rest.startIndex..<quote]))
        }
        return actions
    }

    /// Standalone, the markers are inert: the script that acts on them is not
    /// loaded and there is no panel URL to return to.  Pinned as its own test
    /// because the whole safety of marking the forms unconditionally rests on
    /// it.
    @Test func standaloneEditPageCarriesTheMarkersButNotTheInterceptor() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_wb8", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_wb8", title: "Inert Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        markedFormActions(in: html).contains(
                            "/instructor/\(assignment.publicID)/edit/save"))
                    #expect(!html.contains("/inplace-forms.js"))
                    #expect(!html.contains("data-ck-panel-url=\""))
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
                "/instructor/\(assignment.publicID)/workbench"
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
