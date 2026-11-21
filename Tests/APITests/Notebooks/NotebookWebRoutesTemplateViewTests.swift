import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The template and rendered views of a personalized notebook for staff
/// authors, and how a staff working copy follows the stored starter.
@Suite(.serialized) final class NotebookWebRoutesTemplateViewTests: NotebookWebRoutesFixture {

    let tmpDir: String
    let publicDir: String

    let app: Application

    init() async throws {
        let fixture = try await makeNotebookWebRoutesApp()
        self.app = fixture.app
        self.tmpDir = fixture.tmpDir
        self.publicDir = fixture.publicDir
    }

    // MARK: - Template vs rendered view (staff authoring)

    /// Manifest with one personalized global, and the matching one-code-cell
    /// template — the smallest fixture in which the two views differ.
    private var personalizedManifest: String {
        """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,"globalVariables":[{"name":"patients","value":[{"name":"Maria","age":42}]}]}
        """
    }

    @Test func notebookSourceServesTheTemplateToStaffAndTheRenderingToStudents() async throws {
        try await withApp(app) { _ in
            // The author's default view is the template: `{{patients}}` reaches
            // the editor intact, which is what makes it editable. A student
            // asking for the same notebook still gets their own rendering —
            // a raw placeholder is not valid Python and would not run.
            let setupID = "setup_nb_view_template"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Template Lab", isOpen: true)

            let staffLogin = try await staffCookie(username: "notebook_view_staff")
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("{{patients}}"))
                })

            let studentLogin = try await loginAsStudent("notebook_student", on: app)
            try await enroll(try await studentUser())
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("{{patients}}") == false)
                    #expect(res.body.string.contains("Maria"))
                })
        }
    }

    @Test func notebookSourceRefusesATemplateViewToStudents() async throws {
        try await withApp(app) { _ in
            // The view is resolved from the caller's role, not from the URL:
            // asking for `?view=template` as a student must not hand over the
            // un-substituted notebook.
            let setupID = "setup_nb_view_student_template"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Forced Lab", isOpen: true)

            let studentLogin = try await loginAsStudent("notebook_view_forcer", on: app)
            try await enroll(
                try #require(
                    try await APIUser.query(on: app.db)
                        .filter(\.$username == "notebook_view_forcer").first()))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=template",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("{{patients}}") == false)
                })
        }
    }

    @Test func notebookSourceRejectsSolutionFileForStudent() async throws {
        try await withApp(app) { _ in
            // The page route has always guarded the reference solution; the raw
            // content endpoint did not, so `?file=solution` handed any enrolled
            // student the answer key as JSON.
            let setupID = "setup_nb_source_solution"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(markdown: "Starter"),
                zipEntries: [
                    ("assignment.ipynb", notebookJSON(markdown: "Starter")),
                    ("solution.ipynb", notebookJSON(code: "answer = 42")),
                ])
            _ = try await insertAssignment(testSetupID: setupID, title: "Guarded Lab", isOpen: true)

            let studentLogin = try await loginAsStudent("notebook_source_peeker", on: app)
            try await enroll(
                try #require(
                    try await APIUser.query(on: app.db)
                        .filter(\.$username == "notebook_source_peeker").first()))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?file=solution",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentLogin) },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                    #expect(res.body.string.contains("answer = 42") == false)
                })

            let staffLogin = try await staffCookie(username: "notebook_source_owner")
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?file=solution",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in #expect(res.status == .ok) })
        }
    }

    @Test func notebookPageOffersTheViewSwitchOnlyWhenPlaceholdersExist() async throws {
        try await withApp(app) { _ in
            // The switch is an affordance for a real difference: without
            // placeholders the two views are the same bytes, so offering it
            // would be noise.
            let staffLogin = try await staffCookie(username: "notebook_view_switch_staff")

            let personalizedID = "setup_nb_switch_yes"
            _ = try await insertSetup(
                id: personalizedID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(
                testSetupID: personalizedID, title: "Switch Lab", isOpen: true)

            // The switch is a link to the same notebook in the other view; the
            // `?view=` on the content-fetch URL is not it, so match the href.
            func toggleHref(_ setupID: String, to view: String) -> String {
                #"href="/testsetups/\#(setupID)/notebook?file=assignment&amp;view=\#(view)""#
            }

            try await app.asyncTest(
                .GET, "/testsetups/\(personalizedID)/notebook?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(toggleHref(personalizedID, to: "personalized")))
                    // Submit belongs to the rendered view — a template does not run.
                    #expect(res.body.string.contains(#"id="nb-submit""#) == false)
                })

            try await app.asyncTest(
                .GET, "/testsetups/\(personalizedID)/notebook?view=personalized",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(toggleHref(personalizedID, to: "template")))
                    // Staff never get Submit: it reads as a second save.
                    #expect(res.body.string.contains(#"id="nb-submit""#) == false)
                })

            let plainID = "setup_nb_switch_no"
            _ = try await insertSetup(id: plainID, notebookJSON: notebookJSON(markdown: "Plain"))
            _ = try await insertAssignment(testSetupID: plainID, title: "Plain Lab", isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(plainID)/notebook?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(toggleHref(plainID, to: "template")) == false)
                    #expect(res.body.string.contains(toggleHref(plainID, to: "personalized")) == false)
                    #expect(res.body.string.contains(#"id="nb-submit""#) == false)
                })
        }
    }

    @Test func staffGetSubmitOnTheStudentViewAndSaveOnTheEditingView() async throws {
        try await withApp(app) { _ in
            // The student view is the same for everyone, so staff test-submit
            // there as a student does. "Save to assignment" is on the editing
            // view only, and the two never show together.
            let staffLogin = try await staffCookie(username: "notebook_staff_views")
            let setupID = "setup_nb_staff_views"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Open"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Staff Lab", isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains(#"id="nb-submit""#))
                    #expect(html.contains("nb-menu-upload-file"))
                    #expect(html.contains(#"id="nb-save-assignment""#) == false)
                })

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains(#"id="nb-save-assignment""#))
                    #expect(html.contains(#"id="nb-submit""#) == false)
                    #expect(html.contains("nb-menu-upload-file") == false)
                })
        }
    }

    @Test func staffOnTheStudentViewWorkInACopyApartFromTheAuthoringCopy() async throws {
        try await withApp(app) { _ in
            // A test attempt must never reach a save: the authoring copy is
            // what "Save to assignment" writes back for every student.
            let staffLogin = try await staffCookie(username: "notebook_staff_practice")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_practice").first())
            let userID = try staff.requireID()
            let setupID = "setup_nb_staff_practice"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Starter text"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Practice Lab", isOpen: true)

            let practicePath =
                publicDir + "jupyterlite/files/"
                + staffPracticeWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: .assignment)
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("-practice.ipynb"))
                })
            #expect(FileManager.default.fileExists(atPath: practicePath))

            // A test attempt in the practice copy stays out of the authoring copy.
            try Data(notebookJSON(markdown: "My test answer").utf8).write(to: URL(fileURLWithPath: practicePath))
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains("Starter text"))
                    #expect(res.body.string.contains("My test answer") == false)
                })
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in #expect(res.body.string.contains("My test answer")) })

            // Reset on the student view restores the practice copy only.
            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: staffLogin, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            let restored = try String(contentsOf: URL(fileURLWithPath: practicePath), encoding: .utf8)
            #expect(restored.contains("Starter text"))
            #expect(restored.contains("My test answer") == false)
        }
    }

    @Test func saveNotebookFromEditorStoresHandAuthoredPlaceholders() async throws {
        try await withApp(app) { _ in
            // The point of the template view: an author types `{{name}}` into a
            // cell and it is stored as written, rather than being treated as a
            // rendering and reverted.
            let cookie = try await staffCookie(username: "notebook_author_placeholder")

            let setupID = "setup_nb_author_placeholder"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Authoring Lab", isOpen: false)

            // Untagged, because a template copy is never substituted — this is
            // exactly what the editor holds after the author edits it.
            let authored = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","id":"cell-one","execution_count":null,"metadata":{},"outputs":[],\
                "source":["patients = {{patients}}\\nfirst = {{patients}}[0]"]}]}
                """

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, view: "template", body: authored
            ) { res in
                #expect(res.status == .ok)
            }

            let storedPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            let stored = try String(contentsOfFile: storedPath, encoding: .utf8)
            #expect(stored.contains("first = {{patients}}[0]"), "The authored placeholder must survive the save")
        }
    }

    /// On the IndexedDB drive (`ck_server_drive=0`) the rendered copy is a
    /// view and is dropped; on the server drive it is a draft (#2925), kept and
    /// refreshed on its next fetch because it has no unpublished edits.
    @Test(arguments: [false, true])
    func savingTheTemplateRefreshesTheRenderedView(serverDrive: Bool) async throws {
        try await withApp(app) { _ in
            // The two views are separate files and an existing working copy is
            // returned untouched, so a template save has to invalidate the
            // rendered copy — otherwise switching views after a save shows the
            // notebook as it stood before it.
            let username = serverDrive ? "notebook_view_refresh_drive" : "notebook_view_refresh"
            let session = try await staffCookie(username: username)
            let optOut = serverDrive ? nil : "ck_server_drive=0"
            let cookie = optOut.map { session + "; " + $0 } ?? session
            let staff = try #require(
                try await APIUser.query(on: app.db)
                    .filter(\.$username == username).first())
            let staffID = try staff.requireID()

            let setupID = serverDrive ? "setup_nb_view_refresh_drive" : "setup_nb_view_refresh"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Refresh Lab", isOpen: false)

            // Seed the rendered copy, so there is a stale file to invalidate.
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=personalized&edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("Maria")) })

            let authored = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","id":"cell-one","execution_count":null,"metadata":{},"outputs":[],\
                "source":["cohort = {{patients}}"]}]}
                """
            try await postNotebookSave(
                setupID: setupID, cookie: session, view: "template", extraCookie: optOut, body: authored
            ) { res in
                #expect(res.status == .ok)
            }

            let renderedPath =
                publicDir + "jupyterlite/files/"
                + userNotebookWorkingCopyRelativePath(
                    setupID: setupID, userID: staffID, fileKind: .assignment, viewMode: .personalized)
            #expect(
                FileManager.default.fileExists(atPath: renderedPath) == serverDrive,
                "On the IndexedDB drive the stale rendered copy is dropped; on the server drive it is a draft and stays"
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=personalized&edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("cohort = "))
                    #expect(res.body.string.contains("Maria"))
                })
        }
    }

    @Test func staffWorkingCopyFollowsTheStoredStarter() async throws {
        try await withApp(app) { _ in
            // Staff open the stored notebook as it is now, not the copy made on
            // their first visit. That copy outlives every change made elsewhere
            // (an MCP edit, another author's save, a version restore), and a
            // staff member who saved it would write the old notebook back over
            // the new one.
            let cookie = try await staffCookie(username: "notebook_staff_starter")

            let setupID = "setup_nb_staff_starter"
            let setup = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "First starter"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Follow Lab", isOpen: false)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("First starter")) })

            let notebookPath = try #require(setup.notebookPath)
            try Data(notebookJSON(markdown: "Second starter").utf8).write(to: URL(fileURLWithPath: notebookPath))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("Second starter"))
                    #expect(res.body.string.contains("First starter") == false)
                })
        }
    }

    /// On the server drive a staff copy is a draft (#2925): when the stored
    /// notebook changes elsewhere while the draft holds an unpublished edit,
    /// the content fetch serves the stored notebook and the edit is kept in a
    /// dated backup beside the draft.
    @Test func aStaffDraftWithUnpublishedEditsIsKeptInABackup() async throws {
        try await withApp(app) { _ in
            let cookie = try await staffCookie(username: "notebook_staff_draft")
            let setupID = "setup_nb_staff_draft"
            let setup = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "First starter"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Draft Lab", isOpen: false)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("First starter")) })

            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_draft").first())
            let folder =
                publicDir + "jupyterlite/files/users/\(try staff.requireID().uuidString.lowercased())/\(setupID)/"
            let names = try FileManager.default.contentsOfDirectory(atPath: folder)
            let draftName = try #require(names.first(where: { $0.hasSuffix(".ipynb") }))
            try Data(notebookJSON(markdown: "My unpublished edit").utf8)
                .write(to: URL(fileURLWithPath: folder + draftName))
            try Data(notebookJSON(markdown: "Second starter").utf8)
                .write(to: URL(fileURLWithPath: try #require(setup.notebookPath)))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("Second starter"))
                    #expect(res.body.string.contains("My unpublished edit") == false)
                })
            let backups = try FileManager.default.contentsOfDirectory(atPath: folder)
                .filter { $0.contains("(unsaved draft ") }
            #expect(backups.count == 1)
            let backup = try String(contentsOfFile: folder + (backups.first ?? ""), encoding: .utf8)
            #expect(backup.contains("My unpublished edit"))
        }
    }

    @Test func staffWorkingCopyFollowsAnotherAuthorsSolutionSave() async throws {
        try await withApp(app) { _ in
            let cookie = try await staffCookie(username: "notebook_staff_reader")
            let otherAuthor = try await staffCookie(username: "notebook_staff_author")

            // The solution lives in a validation submission, as an editor or
            // MCP save stores it. A `solution.*` bundled in the setup zip takes
            // precedence over every save, so it would hide the change under test.
            let setupID = "setup_nb_staff_solution"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Assignment"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Solution Follow Lab", isOpen: false)
            try await postNotebookSave(
                setupID: setupID, cookie: otherAuthor, file: "solution",
                body: notebookJSON(markdown: "First solution")
            ) { res in
                #expect(res.status == .ok)
            }

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?file=solution&edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("First solution")) })

            try await postNotebookSave(
                setupID: setupID, cookie: otherAuthor, file: "solution",
                body: notebookJSON(markdown: "Second solution")
            ) { res in
                #expect(res.status == .ok)
            }

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?file=solution&edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("Second solution"))
                    #expect(res.body.string.contains("First solution") == false)
                })
        }
    }

    @Test func unchangedStaffWorkingCopyKeepsItsModificationTime() async throws {
        try await withApp(app) { _ in
            // The editor keeps its in-browser edits while the copy's mtime is
            // unchanged and reloads the copy when it moves. A refresh that
            // rewrote an identical copy on every visit would discard those
            // edits on every reload.
            let cookie = try await staffCookie(username: "notebook_staff_mtime")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_mtime").first())

            let setupID = "setup_nb_staff_mtime"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Stable starter"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Mtime Lab", isOpen: false)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .ok) })

            let copyPath = workingCopyPath(setupID: setupID, userID: try staff.requireID())
            let earlier = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: copyPath)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("Stable starter")) })

            #expect(workingCopyMtimeEpoch(absolutePath: copyPath) == Int(earlier.timeIntervalSince1970))
        }
    }

    @Test func authorsOwnSolutionSaveDoesNotRefreshTheirCopy() async throws {
        try await withApp(app) { _ in
            // The save writes the author's copy and the stored solution as two
            // separate serializations, and the stored solution is normalized
            // again on every read. Neither may count as a change, or the next
            // visit would move the mtime and reload over the author's open tab.
            let cookie = try await staffCookie(username: "notebook_staff_own_save")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_own_save").first())

            let setupID = "setup_nb_staff_own_save"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Assignment"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Own Save Lab", isOpen: false)

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, file: "solution",
                body: notebookJSON(markdown: "Saved solution")
            ) { res in
                #expect(res.status == .ok)
            }

            let copyPath =
                publicDir + "jupyterlite/files/"
                + userNotebookWorkingCopyRelativePath(
                    setupID: setupID, userID: try staff.requireID(), fileKind: .solution, viewMode: .personalized)
            let earlier = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: copyPath)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?file=solution",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("Saved solution")) })

            #expect(workingCopyMtimeEpoch(absolutePath: copyPath) == Int(earlier.timeIntervalSince1970))
        }
    }

    @Test func unchangedPersonalizedStaffCopyKeepsItsModificationTime() async throws {
        try await withApp(app) { _ in
            // The rendered view is substituted on every read, which re-encodes
            // the notebook; an unchanged rendering must still leave the copy
            // alone.
            let cookie = try await staffCookie(username: "notebook_staff_rendered")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_staff_rendered").first())

            let setupID = "setup_nb_staff_rendered"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Rendered Lab", isOpen: false)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=personalized&edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("Maria")) })

            let copyPath =
                publicDir + "jupyterlite/files/"
                + userNotebookWorkingCopyRelativePath(
                    setupID: setupID, userID: try staff.requireID(), fileKind: .assignment, viewMode: .personalized)
            let earlier = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: copyPath)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=personalized&edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("Maria")) })

            #expect(workingCopyMtimeEpoch(absolutePath: copyPath) == Int(earlier.timeIntervalSince1970))
        }
    }
}
