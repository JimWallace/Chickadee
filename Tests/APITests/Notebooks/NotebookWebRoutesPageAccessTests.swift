import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The notebook page in embedded mode, and who may open and edit it while an
/// assignment is open, closed, unpublished or extended.
@Suite(.serialized) final class NotebookWebRoutesPageAccessTests: NotebookWebRoutesFixture {

    let tmpDir: String
    let publicDir: String

    let app: Application

    init() async throws {
        let fixture = try await makeNotebookWebRoutesApp()
        self.app = fixture.app
        self.tmpDir = fixture.tmpDir
        self.publicDir = fixture.publicDir
    }

    // MARK: - Embedded mode (assignment workbench panes)

    /// `?embedded=1` renders the same page without the site chrome, so the
    /// notebook can be composed into a workbench pane without three stacked
    /// copies of the nav.  Asserted against the *same* setup in both modes so
    /// the only difference under test is the flag.
    @Test func notebookPageEmbeddedDropsSiteChromeButKeepsEditor() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_embedded"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Embedded seed"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Embedded Lab")

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("<nav class=\"nav\""), "Standalone page keeps the site nav")
                    #expect(html.contains("/idle-logout.js"))
                    #expect(!html.contains("jl-frame-embedded"))
                })

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?embedded=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Chrome gone …
                    #expect(!html.contains("<nav class=\"nav\""), "Embedded pane must not render the site nav")
                    #expect(!html.contains("skip-link"))
                    // … the idle watchdog loads unconditionally now.  It is a
                    // no-op here — an embedded rendering has no logout form, so
                    // `idle-logout.js` bails on its own — and #1266 deleted the
                    // `embedded-activity.js` forwarder that used to be swapped
                    // in for it.  That forwarder existed because the watchdog
                    // lived in a *parent* document while the keystrokes landed
                    // in this one; the workbench is a single document now, so
                    // there is nothing to forward across.
                    #expect(!html.contains("/embedded-activity.js"))
                    // … and the editor itself is untouched, now pane-height.
                    #expect(html.contains("data-setup-id=\"\(setupID)\""))
                    #expect(html.contains("jl-frame-embedded"))
                })
        }
    }

    /// `embedded` is a rendering hint, never a permission.  A student who
    /// appends it to a solution URL gets the same 403 as without it — the
    /// staff-only guard runs before the flag is ever consulted.
    @Test func embeddedFlagGrantsNoAccessToTheSolution() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_embedded_sol"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Seed"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Embedded Solution Guard")

            for path in [
                "/testsetups/\(setupID)/notebook?file=solution&embedded=1",
                "/testsetups/\(setupID)/notebook/source?file=solution&embedded=1",
            ] {
                try await app.asyncTest(
                    .GET, path,
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in
                        #expect(res.status == .forbidden, "Expected 403 for \(path)")
                    })
            }
        }
    }

    @Test func notebookPageSeedsWorkingCopyAndRendersEditorFrame() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_page"
            let seedNotebook = notebookJSON(markdown: "Notebook seed")
            _ = try await insertSetup(id: setupID, notebookJSON: seedNotebook)
            _ = try await insertAssignment(testSetupID: setupID, title: "Notebook Lab")

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("data-setup-id=\"\(setupID)\""))
                    #expect(
                        html.contains("data-notebook-url=\"/testsetups/\(setupID)/notebook/source?file=assignment"))
                    #expect(html.contains("/jupyterlite/notebooks/index.html?workspace=\(setupID)-"))
                    #expect(html.contains("&amp;path=users/"))
                    // v0.4.153 cache-bust: the iframe is stamped with the
                    // working-copy mtime so notebook.js can force-reseed when the
                    // server overwrites the file (instructor "Reset" action).
                    // Extract the value and assert it's a positive integer.
                    guard let match = html.firstMatch(of: /data-working-copy-mtime="(\d+)"/),
                        let mtime = Int(match.output.1)
                    else {
                        Issue.record("Expected data-working-copy-mtime=\"<int>\" attribute on iframe")
                        return
                    }
                    #expect(mtime > 0, "Working-copy mtime should be a positive Unix-epoch timestamp")
                })

            let workingCopy = try String(
                contentsOfFile: workingCopyPath(setupID: setupID, userID: try user.requireID()),
                encoding: .utf8
            )
            #expect(workingCopy.contains("Notebook seed"))
            #expect(workingCopy.contains("\"display_name\":\"Python (xeus-python)\""))

        }
    }

    @Test func notebookPageOpenAssignmentRendersSubmitAndEditableIframe() async throws {
        try await withApp(app) { _ in
            // Open assignment: data-read-only="false", Submit button rendered,
            // no "closed" notice.
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_open"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Open"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Open Lab", dueAt: nil, isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        html.contains(#"data-read-only="false""#),
                        "Open assignment iframe must carry data-read-only=\"false\"")
                    #expect(
                        html.contains(#"id="nb-submit""#),
                        "Open assignment must render the Submit button")
                    #expect(
                        html.contains("This assignment is closed") == false,
                        "Open assignment must not render the closed-view notice")
                })

        }
    }

    @Test func notebookPageClosedAssignmentRendersReadOnlyAndHidesSubmit() async throws {
        try await withApp(app) { _ in
            // Closed assignment (deadline past, no override) the student has
            // previously opened: the iframe must carry data-read-only="true",
            // the Submit button must disappear, and the closed-view notice must
            // appear.  This is the core contract for the closed-assignment
            // read-only review view.
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_closed"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Closed"))
            let assignment = try await insertAssignment(
                testSetupID: setupID,
                title: "Closed Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),  // due 1h ago
                isOpen: true  // not explicitly closed; deadline carries it
            )

            // Mark the assignment as previously opened by recording a
            // participation row — otherwise the closed-assignment gate would
            // redirect them to the dashboard (covered by the next test).
            try await APIAssignmentParticipation(
                userID: try user.requireID(), assignmentID: try assignment.requireID()
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        html.contains(#"data-read-only="true""#),
                        "Closed assignment iframe must carry data-read-only=\"true\"")
                    #expect(
                        html.contains(#"id="nb-submit""#) == false,
                        "Closed assignment must NOT render the Submit button")
                    #expect(
                        html.contains("This assignment is closed"),
                        "Closed assignment must render the view-only notice")
                })

        }
    }

    @Test func notebookPageClosedPublishedAssignmentNeverOpenedRendersReadOnly() async throws {
        try await withApp(app) { _ in
            // A published-then-closed assignment (its deadline has passed) is now
            // openable read-only by any enrolled student, even one who never
            // engaged with it — recent labs stay reviewable instead of bouncing
            // the student to the dashboard. Submission remains separately gated,
            // so the view is read-only (no Submit button, closed notice shown).
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_closed_published"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Review me"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Closed Published Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),  // published, deadline passed
                isOpen: true
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains(#"data-read-only="true""#))
                    #expect(html.contains(#"id="nb-submit""#) == false)
                    #expect(html.contains("This assignment is closed"))
                })
        }
    }

    @Test func notebookPageUnpublishedDraftRedirectsToDashboard() async throws {
        try await withApp(app) { _ in
            // A closed assignment with no due date is an unpublished draft, not a
            // lab that ran and closed: a student who never engaged with it is
            // still bounced to the dashboard so authoring-in-progress content and
            // pre-posted links can't spoil it.
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_draft"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Draft"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Draft Lab",
                dueAt: nil,  // no deadline → unpublished draft
                isOpen: false
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                })
        }
    }

    @Test func notebookPageExtendedStudentGetsEditableClosedAssignmentEvenIfNeverStarted() async throws {
        try await withApp(app) { _ in
            // CRITICAL: a per-student extension must let the student COMPLETE a
            // closed assignment for full credit, even one they never started.
            // The notebook page must render EDITABLE (not read-only) with the
            // Submit button, because the extension makes it effectively open for
            // this student — independent of any prior participation.
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_extension_editable"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Extend me"))
            let assignment = try await insertAssignment(
                testSetupID: setupID,
                title: "Extended Closed Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),  // deadline passed
                isOpen: false  // assignment-wide visibility is closed
            )
            // Grant a future extension. The student has NEVER opened this
            // assignment — no participation row, no submission.
            try await APIAssignmentExtension(
                assignmentID: try assignment.requireID(),
                userID: try user.requireID(),
                extendedDueAt: Date(timeIntervalSinceNow: 48 * 3600)
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        html.contains(#"data-read-only="false""#),
                        "An extended student must get an EDITABLE notebook on a closed assignment")
                    #expect(
                        html.contains(#"id="nb-submit""#),
                        "An extended student must see the Submit button so they can complete it")
                    #expect(html.contains("This assignment is closed") == false)
                })
        }
    }

    @Test func notebookPageRejectsSolutionFileForStudent() async throws {
        try await withApp(app) { _ in
            // The reference solution is staff-only. A student crafting
            // ?file=solution on the notebook route must be refused — the answer
            // key is never served to a student, on any assignment.
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_solution_student"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(markdown: "Assignment"),
                zipEntries: [
                    ("assignment.ipynb", notebookJSON(markdown: "Assignment")),
                    ("solution.ipynb", notebookJSON(markdown: "Reference solution")),
                ]
            )
            _ = try await insertAssignment(testSetupID: setupID, title: "Solution Guard Lab", isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?file=solution",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
        }
    }

    @Test func notebookPageAllowsSolutionFileForInstructor() async throws {
        try await withApp(app) { _ in
            // Course staff may view the solution on the same route — the guard is
            // role-based, not a blanket block, so instructor preview still works.
            let cookie = try await loginUser(
                username: "notebook_instructor", password: "testpassword", role: "instructor", on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_instructor").first())
            try await enroll(instructor)

            let setupID = "setup_nb_solution_instructor"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(markdown: "Assignment"),
                zipEntries: [
                    ("assignment.ipynb", notebookJSON(markdown: "Assignment")),
                    ("solution.ipynb", notebookJSON(markdown: "Reference solution")),
                ]
            )
            _ = try await insertAssignment(testSetupID: setupID, title: "Solution View Lab", isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?file=solution",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })
        }
    }

    @Test func notebookPageClosedAssignmentStaysEditableForCourseStaff() async throws {
        try await withApp(app) { _ in
            // Course staff author the starter notebook in this editor, and an
            // assignment is closed for the whole window in which it is being
            // written (creation, cloning, and every save return it to closed).
            // The closed state must therefore never lock the editor for staff:
            // the iframe stays editable and the "view only" notice is replaced
            // by the staff-editable one.  Submission stays closed for everyone.
            let cookie = try await loginUser(
                username: "notebook_staff_closed", password: "testpassword", role: "instructor", on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_closed").first())
            try await enroll(instructor)

            let setupID = "setup_nb_closed_staff"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Authoring"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Draft Lab",
                dueAt: nil,  // never published — a freshly created assignment
                isOpen: false
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?edit=1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(
                        html.contains(#"data-read-only="false""#),
                        "Course staff must keep an EDITABLE notebook on a closed assignment")
                    #expect(
                        html.contains("This assignment is closed &mdash; view only.") == false,
                        "Staff must not see the student view-only notice")
                    #expect(
                        html.contains("editable as course staff"),
                        "Staff must see the staff-editable notice instead")
                    #expect(
                        html.contains(#"id="nb-submit""#) == false,
                        "Submission stays gated by the closed state, for staff too")
                })
        }
    }

    @Test func notebookPageClosedAssignmentSolutionStaysEditableForCourseStaff() async throws {
        try await withApp(app) { _ in
            // Same contract for the reference solution: it is authored on a
            // closed assignment, so ?file=solution must render editable too.
            let cookie = try await loginUser(
                username: "notebook_staff_solution", password: "testpassword", role: "instructor", on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_solution").first())
            try await enroll(instructor)

            let setupID = "setup_nb_closed_staff_solution"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(markdown: "Assignment"),
                zipEntries: [
                    ("assignment.ipynb", notebookJSON(markdown: "Assignment")),
                    ("solution.ipynb", notebookJSON(markdown: "Reference solution")),
                ]
            )
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Closed Solution Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),  // deadline passed
                isOpen: false
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?file=solution&edit=1",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains(#"data-read-only="false""#))
                })
        }
    }
}
