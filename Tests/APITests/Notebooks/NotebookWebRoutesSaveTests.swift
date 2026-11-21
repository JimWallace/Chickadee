import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// `POST /testsetups/:id/notebook/save`, the editor's "Save to assignment".
@Suite(.serialized) final class NotebookWebRoutesSaveTests: NotebookWebRoutesFixture {

    let tmpDir: String
    let publicDir: String

    let app: Application

    init() async throws {
        let fixture = try await makeNotebookWebRoutesApp()
        self.app = fixture.app
        self.tmpDir = fixture.tmpDir
        self.publicDir = fixture.publicDir
    }

    // MARK: - POST /testsetups/:id/notebook/save

    @Test func saveNotebookFromEditorReplacesTheStarterNotebook() async throws {
        try await withApp(app) { _ in
            // The editing loop this closes: JupyterLite holds the live document
            // in the browser, so an authoring edit reached the server nowhere
            // before this endpoint. A staff save must land in the setup's flat
            // notebook — the bytes every student's working copy is seeded from —
            // and in the author's own working copy, so a reload shows the save.
            let cookie = try await staffCookie(username: "notebook_save_starter")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_save_starter").first())

            let setupID = "setup_nb_save_starter"
            let setup = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Original"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Authoring Lab", isOpen: false)

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, body: notebookJSON(markdown: "Edited in the editor")
            ) { res in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("\"saved\":true"))
                #expect(body.contains("\"cellCount\":1"))
            }

            let storedPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            let stored = try String(contentsOfFile: storedPath, encoding: .utf8)
            #expect(stored.contains("Edited in the editor"))
            #expect(stored.contains("Original") == false)

            let workingCopy = try String(
                contentsOfFile: workingCopyPath(setupID: setupID, userID: try staff.requireID()),
                encoding: .utf8)
            #expect(workingCopy.contains("Edited in the editor"))
            _ = setup
        }
    }

    @Test func saveNotebookFromEditorLeavesAnOpenAssignmentOpen() async throws {
        try await withApp(app) { _ in
            // Unlike the MCP write tools (and the page's Save & Validate
            // button), this live-edit endpoint never changes visibility:
            // yanking an open lab out from under students mid-session to fix a
            // typo in the starter notebook is worse than the risk, and neither
            // notebook changes what the suite grades.
            let cookie = try await staffCookie(username: "notebook_save_openstate")

            let setupID = "setup_nb_save_openstate"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Original"))
            _ = try await insertAssignment(
                testSetupID: setupID, title: "Live Lab", dueAt: Date(timeIntervalSinceNow: 3600),
                isOpen: true)

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, body: notebookJSON(markdown: "Typo fixed")
            ) { res in
                #expect(res.status == .ok)
            }

            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$testSetupID == setupID).first())
            #expect(assignment.visibility == .open, "A starter-notebook save must not close an open lab")
        }
    }

    @Test func saveNotebookFromEditorStoresSolutionAsValidationSubmission() async throws {
        try await withApp(app) { _ in
            // An assignment's reference solution IS its latest validation
            // submission (that is what `loadExistingSolution` reads and what the
            // Save & Validate path writes), so storing one is what persists a
            // solution edit — and re-validating against the new answer key is
            // the point of saving it.
            let cookie = try await staffCookie(username: "notebook_save_solution")

            let setupID = "setup_nb_save_solution"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(markdown: "Assignment"),
                zipEntries: [
                    ("assignment.ipynb", notebookJSON(markdown: "Assignment")),
                    ("solution.ipynb", notebookJSON(markdown: "Old solution")),
                ])
            _ = try await insertAssignment(testSetupID: setupID, title: "Solution Lab", isOpen: false)

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, file: "solution",
                body: notebookJSON(markdown: "New reference solution")
            ) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("\"fileKind\":\"solution\""))
            }

            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$testSetupID == setupID).first())
            let validationID = try #require(assignment.validationSubmissionID)
            let submission = try #require(try await APISubmission.find(validationID, on: app.db))
            #expect(submission.kind == APISubmission.Kind.validation)
            let stored = try String(contentsOfFile: submission.zipPath, encoding: .utf8)
            #expect(stored.contains("New reference solution"))

            // And the starter notebook is untouched — a solution save must never
            // overwrite what students open.
            let starterPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            #expect(try String(contentsOfFile: starterPath, encoding: .utf8).contains("Assignment"))
        }
    }

    @Test func saveNotebookFromEditorWritesDraftSetupWithNoAssignmentRow() async throws {
        try await withApp(app) { _ in
            // The new-assignment page edits a draft setup that has no assignment
            // row yet, and reads it back through `draftNotebookData` (working
            // copy first). A save there must persist without trying to validate
            // an assignment that does not exist.
            let cookie = try await staffCookie(username: "notebook_save_draft")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "notebook_save_draft").first())

            let setupID = "setup_nb_save_draft"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Draft starter"))

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, body: notebookJSON(markdown: "Draft edited")
            ) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("draft"))
            }

            let workingCopy = try String(
                contentsOfFile: workingCopyPath(setupID: setupID, userID: try staff.requireID()),
                encoding: .utf8)
            #expect(workingCopy.contains("Draft edited"))
        }
    }

    @Test func saveNotebookFromEditorRejectsAStudent() async throws {
        try await withApp(app) { _ in
            // The button is staff-only in the template; the endpoint is what
            // actually enforces it. A student POSTing directly must be refused
            // before anything is written.
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_save_student"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Original"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Student Lab", isOpen: true)

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, body: notebookJSON(markdown: "Student rewrite")
            ) { res in
                #expect(res.status == .forbidden)
            }

            let storedPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            #expect(try String(contentsOfFile: storedPath, encoding: .utf8).contains("Original"))
        }
    }

    @Test func saveNotebookFromEditorRejectsNonNotebookJSON() async throws {
        try await withApp(app) { _ in
            // A body that isn't notebook-shaped must be refused rather than
            // stored: the flat notebook is what every student is seeded from,
            // so a stray POST cannot be allowed to replace it with junk.
            let cookie = try await staffCookie(username: "notebook_save_badjson")

            let setupID = "setup_nb_save_badjson"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Original"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Guard Lab", isOpen: false)

            try await postNotebookSave(
                setupID: setupID, cookie: cookie, body: #"{"not":"a notebook"}"#
            ) { res in
                #expect(res.status == .badRequest)
            }

            let storedPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            #expect(try String(contentsOfFile: storedPath, encoding: .utf8).contains("Original"))
        }
    }

    @Test func saveNotebookFromEditorRestoresPersonalizationTemplates() async throws {
        try await withApp(app) { _ in
            // Every working copy is a *rendering*: the server substitutes the
            // viewer's own values into `{{name}}` and tags the cell. Saving that
            // verbatim would replace the class's template with one person's
            // data, so the tagged cells must be restored from the stored
            // notebook before anything is written.
            let cookie = try await staffCookie(username: "notebook_save_personalized")

            let setupID = "setup_nb_save_personalized"
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,"globalVariables":[{"name":"patients","value":[{"name":"Maria","age":42}]}]}
                """
            // The stored template, with a cell id so the restore has an exact
            // match (what JupyterLite writes for nbformat 4.5).
            let template = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","id":"cell-one","execution_count":null,"metadata":{},"outputs":[],"source":["patients = {{patients}}"]}]}
                """
            _ = try await insertSetup(id: setupID, notebookJSON: template, manifest: manifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Personalized Lab", isOpen: false)

            // What the editor holds after the author edited the *rendered* copy:
            // the substituted literal, tagged as personalized.
            let rendered = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","id":"cell-one","execution_count":null,\
                "metadata":{"chickadee_personalized":"patients"},"outputs":[],\
                "source":["patients = [{'name': 'Maria', 'age': 42}]"]}]}
                """

            try await postNotebookSave(setupID: setupID, cookie: cookie, body: rendered) { res in
                #expect(res.status == .ok)
            }

            let storedPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            let stored = try String(contentsOfFile: storedPath, encoding: .utf8)
            #expect(
                stored.contains("{{patients}}"),
                "The stored notebook must keep its personalization template")
            #expect(
                stored.contains("Maria") == false,
                "One viewer's substituted values must never reach the class template")
        }
    }

    @Test func saveNotebookFromEditorRefusesUnmatchablePersonalizedCell() async throws {
        try await withApp(app) { _ in
            // A personalized cell that can't be matched back to the stored
            // notebook (here: an id that isn't in it) is refused rather than
            // guessed at — a rejected save is recoverable, a template quietly
            // replaced by one student's data is not.
            let cookie = try await staffCookie(username: "notebook_save_unmatched")

            let setupID = "setup_nb_save_unmatched"
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,"globalVariables":[{"name":"patients","value":[{"name":"Maria","age":42}]}]}
                """
            let template = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","id":"cell-one","execution_count":null,"metadata":{},"outputs":[],"source":["patients = {{patients}}"]}]}
                """
            _ = try await insertSetup(id: setupID, notebookJSON: template, manifest: manifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Unmatched Lab", isOpen: false)

            let rendered = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"markdown","id":"intro","metadata":{},"source":["Intro"]},\
                {"cell_type":"code","id":"cell-moved","execution_count":null,\
                "metadata":{"chickadee_personalized":"patients"},"outputs":[],\
                "source":["patients = [{'name': 'Maria', 'age': 42}]"]}]}
                """

            try await postNotebookSave(setupID: setupID, cookie: cookie, body: rendered) { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("{{patients}}"))
            }

            let storedPath = try #require(
                try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
            #expect(try String(contentsOfFile: storedPath, encoding: .utf8).contains("{{patients}}"))
        }
    }
}
