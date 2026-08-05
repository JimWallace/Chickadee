import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class NotebookWebRoutesTests {

    private var tmpRoot: String!
    private var tmpDir: String!
    private var publicDir: String!
    private var repoRoot: String!

    let app: Application

    init() async throws {
        let repoRoot = FileManager.default.currentDirectoryPath
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-notebook-web-\(UUID().uuidString)")
            .path + "/"
        var publicDir = ""

        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            publicDir = app.directory.publicDirectory

            try FileManager.default.createDirectory(
                atPath: tmpRoot, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: tmpRoot + "Resources",
                withDestinationPath: repoRoot + "/Resources"
            )
            try FileManager.default.createDirectory(
                atPath: publicDir, withIntermediateDirectories: true)

            let dirs = ["results/", "testsetups/", "submissions/"].map { tmpRoot + $0 }
            for dir in dirs {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
            }

            app.resultsDirectory = dirs[0]
            app.testSetupsDirectory = dirs[1]
            app.submissionsDirectory = dirs[2]

            app.sessions.use(.memory)
            app.middleware.use(app.sessions.middleware)

            try await configureTestDatabase(app)

            configureLeaf(app)
            try routes(app)
        }

        self.repoRoot = repoRoot
        self.tmpRoot = tmpRoot
        self.tmpDir = tmpRoot
        self.publicDir = publicDir
    }

    private func loginAsStudent(username: String) async throws -> String {
        try await loginUser(
            username: username,
            password: "testpassword",
            role: "student",
            on: app
        )
    }

    private func loginAsStudent() async throws -> String {
        try await loginAsStudent(username: "notebook_student")
    }

    private func studentUser() async throws -> APIUser {
        let user = try await APIUser.query(on: app.db)
            .filter(\.$username == "notebook_student")
            .first()
        return try #require(user)
    }

    private func makeCourse() async throws -> APICourse {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "NOTE185").first() {
            return existing
        }
        let course = APICourse(code: "NOTE185", name: "Notebook Coverage")
        try await course.save(on: app.db)
        return course
    }

    private func enroll(_ user: APIUser) async throws {
        let course = try await makeCourse()
        // Seed the per-course role from the global role (mirroring production
        // saveSeededEnrollment) so a global instructor becomes course staff —
        // the notebook solution view is per-course staff now (#417 Slice G).
        // The global `instructor` UserRole case is gone (#417 Slice G2); a
        // legacy `"instructor"` role string or an admin seeds to instructor.
        let isStaff = (user.role == "instructor") || user.isAdmin
        let enrollment = APICourseEnrollment(
            userID: try user.requireID(),
            courseID: try course.requireID(),
            role: isStaff ? .instructor : .student
        )
        try await enrollment.save(on: app.db)
    }

    @discardableResult
    private func insertSetup(
        id: String,
        notebookJSON: String,
        manifest: String? = nil,
        zipEntries: [(name: String, content: String)] = []
    ) async throws -> APITestSetup {
        let storedManifest =
            manifest ?? """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
                """
        let zipPath = tmpDir + "testsetups/\(id).zip"
        let notebookPath = tmpDir + "testsetups/\(id).ipynb"
        let entries = zipEntries.isEmpty ? [("assignment.ipynb", notebookJSON)] : zipEntries
        try makeZipAt(zipPath: zipPath, entries: entries)
        try Data(notebookJSON.utf8).write(to: URL(fileURLWithPath: notebookPath))

        let setup = APITestSetup(
            id: id,
            manifest: storedManifest,
            zipPath: zipPath,
            notebookPath: notebookPath,
            courseID: try await makeCourse().requireID()
        )
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(
        testSetupID: String,
        title: String,
        dueAt: Date? = nil,
        startsAt: Date? = nil,
        isOpen: Bool = true
    ) async throws -> APIAssignment {
        let assignment = APIAssignment(
            testSetupID: testSetupID,
            title: title,
            dueAt: dueAt,
            startsAt: startsAt,
            isOpen: isOpen,
            courseID: try await makeCourse().requireID()
        )
        try await assignment.save(on: app.db)
        return assignment
    }

    @discardableResult
    private func insertNotebookSubmission(
        id: String,
        testSetupID: String,
        userID: UUID,
        notebookJSON: String,
        attemptNumber: Int = 1
    ) async throws -> APISubmission {
        let path = tmpDir + "submissions/\(id).ipynb"
        try Data(notebookJSON.utf8).write(to: URL(fileURLWithPath: path))
        let submission = APISubmission(
            id: id,
            testSetupID: testSetupID,
            zipPath: path,
            attemptNumber: attemptNumber,
            status: "complete",
            filename: "\(id).ipynb",
            userID: userID,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        return submission
    }

    private func workingCopyPath(setupID: String, userID: UUID) -> String {
        publicDir + "jupyterlite/files/" + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
    }

    private func notebookJSON(markdown: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":[\(markdown.debugDescription)]}]}
        """
    }

    /// Single-code-cell notebook — personalization substitution only rewrites
    /// code cells, so `{{name}}` fixtures need this shape.
    private func notebookJSON(code: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":[\(code.debugDescription)]}]}
        """
    }

    private func makeZipAt(zipPath: String, entries: [(name: String, content: String)]) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/env") else {
            throw IssueRecorded("env not available")
        }

        let entriesCode = entries.map { entry in
            "z.writestr(\(entry.name.debugDescription), \(entry.content.debugDescription))"
        }.joined(separator: "\n    ")
        let script = """
            import zipfile
            with zipfile.ZipFile('\(zipPath)', 'w') as z:
                \(entriesCode)
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IssueRecorded("python3 not available or failed to create zip")
        }
    }

    // MARK: - Embedded mode (assignment workbench panes)

    /// `?embedded=1` renders the same page without the site chrome, so the
    /// notebook can be composed into a workbench pane without three stacked
    /// copies of the nav.  Asserted against the *same* setup in both modes so
    /// the only difference under test is the flag.
    @Test func notebookPageEmbeddedDropsSiteChromeButKeepsEditor() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
                    let mtimeRegex = try NSRegularExpression(pattern: #"data-working-copy-mtime="(\d+)""#)
                    let nsr = NSRange(html.startIndex..., in: html)
                    guard let match = mtimeRegex.firstMatch(in: html, range: nsr),
                        let valueRange = Range(match.range(at: 1), in: html),
                        let mtime = Int(html[valueRange])
                    else {
                        Issue.record("Expected data-working-copy-mtime=\"<int>\" attribute on iframe"); return
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
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
            let cookie = try await loginAsStudent()
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
                .GET, "/testsetups/\(setupID)/notebook",
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
                .GET, "/testsetups/\(setupID)/notebook?file=solution",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains(#"data-read-only="false""#))
                })
        }
    }

    // MARK: - POST /testsetups/:id/notebook/save

    /// Drives the editor's "Save to assignment" endpoint with `body` as the
    /// notebook JSON, mirroring what `notebook.js` sends (JSON body + the CSRF
    /// token in a header).
    private func postNotebookSave(
        setupID: String,
        cookie: String,
        file: String? = nil,
        view: String? = nil,
        body: String,
        afterResponse: (TestingHTTPResponse) throws -> Void
    ) async throws {
        let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        let params = [file.map { "file=\($0)" }, view.map { "view=\($0)" }].compactMap { $0 }
        let query = params.isEmpty ? "" : "?" + params.joined(separator: "&")
        try await app.asyncTest(
            .POST, "/testsetups/\(setupID)/notebook/save\(query)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.add(name: "x-csrf-token", value: csrf)
                req.headers.contentType = .json
                req.body = ByteBufferAllocator().buffer(string: body)
            },
            afterResponse: afterResponse)
    }

    private func staffCookie(username: String) async throws -> String {
        let cookie = try await loginUser(
            username: username, password: "testpassword", role: "instructor", on: app)
        let staff = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await enroll(staff)
        return cookie
    }

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
            let cookie = try await loginAsStudent()
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
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("{{patients}}"))
                })

            let studentLogin = try await loginAsStudent()
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

            let studentLogin = try await loginAsStudent(username: "notebook_view_forcer")
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

            let studentLogin = try await loginAsStudent(username: "notebook_source_peeker")
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
                .GET, "/testsetups/\(personalizedID)/notebook",
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
                    #expect(res.body.string.contains(#"id="nb-submit""#))
                })

            let plainID = "setup_nb_switch_no"
            _ = try await insertSetup(id: plainID, notebookJSON: notebookJSON(markdown: "Plain"))
            _ = try await insertAssignment(testSetupID: plainID, title: "Plain Lab", isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(plainID)/notebook",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(toggleHref(plainID, to: "template")) == false)
                    #expect(res.body.string.contains(toggleHref(plainID, to: "personalized")) == false)
                    // Nothing about a plain assignment changes for staff.
                    #expect(res.body.string.contains(#"id="nb-submit""#))
                })
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

    @Test func savingTheTemplateRefreshesTheRenderedView() async throws {
        try await withApp(app) { _ in
            // The two views are separate files and an existing working copy is
            // returned untouched, so a template save has to invalidate the
            // rendered copy — otherwise switching views after a save shows the
            // notebook as it stood before it.
            let cookie = try await staffCookie(username: "notebook_view_refresh")
            let staff = try #require(
                try await APIUser.query(on: app.db)
                    .filter(\.$username == "notebook_view_refresh").first())
            let staffID = try staff.requireID()

            let setupID = "setup_nb_view_refresh"
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: personalizedManifest)
            _ = try await insertAssignment(testSetupID: setupID, title: "Refresh Lab", isOpen: false)

            // Seed the rendered copy, so there is a stale file to invalidate.
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=personalized",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.body.string.contains("Maria")) })

            let authored = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
                {"cell_type":"code","id":"cell-one","execution_count":null,"metadata":{},"outputs":[],\
                "source":["cohort = {{patients}}"]}]}
                """
            try await postNotebookSave(
                setupID: setupID, cookie: cookie, view: "template", body: authored
            ) { res in
                #expect(res.status == .ok)
            }

            let renderedPath =
                publicDir + "jupyterlite/files/"
                + userNotebookWorkingCopyRelativePath(
                    setupID: setupID, userID: staffID, fileKind: .assignment, viewMode: .personalized)
            #expect(
                FileManager.default.fileExists(atPath: renderedPath) == false,
                "The stale rendered copy must be dropped so it reseeds from the saved template")

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source?view=personalized",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("cohort = "))
                    #expect(res.body.string.contains("Maria"))
                })
        }
    }

    @Test func notebookPageRendersSaveButtonForStaffOnly() async throws {
        try await withApp(app) { _ in
            // The authoring control is rendered server-side, so a student never
            // receives the markup for it.
            let staffLogin = try await staffCookie(username: "notebook_save_button_staff")
            let setupID = "setup_nb_save_button"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Button"))
            _ = try await insertAssignment(testSetupID: setupID, title: "Button Lab", isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(#"id="nb-save-assignment""#))
                })

            let studentLogin = try await loginAsStudent()
            let student = try await studentUser()
            try await enroll(student)
            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(#"id="nb-save-assignment""#) == false)
                })
        }
    }

    @Test func notebookPageNotYetOpenAssignmentRedirectsToDashboard() async throws {
        try await withApp(app) { _ in
            // A student following a pre-posted link to an assignment whose open
            // date is still in the future is bounced to their dashboard rather
            // than into the notebook — the future `startsAt` holds it closed for
            // everyone, so the closed-assignment gate fires just as it does for a
            // past-deadline lab.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_not_yet_open"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Future"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Scheduled Lab",
                dueAt: Date(timeIntervalSinceNow: 7 * 24 * 3600),
                startsAt: Date(timeIntervalSinceNow: 24 * 3600),
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

    @Test func resetOwnNotebookRestoresStarterForOpenAssignment() async throws {
        try await withApp(app) { _ in
            // A student self-resets their own working copy: the corrupted copy is
            // overwritten with the canonical starter and they are bounced back to
            // the dashboard.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)
            let userID = try user.requireID()

            let setupID = "setup_nb_self_reset"
            let starterMarker = "Original starter cell"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: starterMarker))
            _ = try await insertAssignment(testSetupID: setupID, title: "Self Reset Lab", isOpen: true)

            // Simulate the student having clobbered their own working copy.
            let copyPath = workingCopyPath(setupID: setupID, userID: userID)
            try FileManager.default.createDirectory(
                atPath: (copyPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try Data(notebookJSON(markdown: "Broken edits").utf8)
                .write(to: URL(fileURLWithPath: copyPath))

            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                })

            let restored = try String(contentsOf: URL(fileURLWithPath: copyPath), encoding: .utf8)
            #expect(restored.contains(starterMarker))
            #expect(restored.contains("Broken edits") == false)
        }
    }

    @Test func resetOwnNotebookAppliesPersonalizationSubstitutions() async throws {
        try await withApp(app) { _ in
            // Regression: a self-reset on a personalized assignment must hand
            // back the *substituted* starter, exactly like first-open seeding.
            // The reset used to write the raw template, so the student's first
            // cell became `patients = {{patients}}` — a NameError with no
            // self-service way back to their data.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)
            let userID = try user.requireID()

            let setupID = "setup_nb_self_reset_personalized"
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,"globalVariables":[{"name":"patients","value":[{"name":"Maria","age":42}]}]}
                """
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(code: "patients = {{patients}}"),
                manifest: manifest
            )
            _ = try await insertAssignment(testSetupID: setupID, title: "Personalized Reset Lab", isOpen: true)

            // Simulate the student having clobbered their own working copy.
            let copyPath = workingCopyPath(setupID: setupID, userID: userID)
            try FileManager.default.createDirectory(
                atPath: (copyPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try Data(notebookJSON(markdown: "Broken edits").utf8)
                .write(to: URL(fileURLWithPath: copyPath))

            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let restored = try String(contentsOf: URL(fileURLWithPath: copyPath), encoding: .utf8)
            #expect(
                restored.contains("{{patients}}") == false,
                "Reset must substitute the {{patients}} placeholder — the raw template leaves the student with a NameError."
            )
            #expect(restored.contains("Maria"), "Reset working copy must carry the substituted value.")
            #expect(restored.contains("Broken edits") == false)
        }
    }

    @Test func resetOwnNotebookRejectedForClosedAssignment() async throws {
        try await withApp(app) { _ in
            // The self-reset route is gated on the assignment being open to the
            // student; a past-deadline assignment is refused with 403.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_self_reset_closed"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Starter"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Closed Self Reset Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),
                isOpen: true
            )

            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
        }
    }

    @Test func notebookPageClosedAssignmentWithSubmissionStaysReachable() async throws {
        try await withApp(app) { _ in
            // Having submitted at least once also counts as "previously opened",
            // so a closed assignment with a prior submission renders the
            // read-only review view rather than redirecting.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_closed_submitted"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Submitted"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Submitted Closed Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),
                isOpen: true
            )
            _ = try await insertNotebookSubmission(
                id: "sub_nb_closed_submitted",
                testSetupID: setupID,
                userID: try user.requireID(),
                notebookJSON: notebookJSON(markdown: "My answer")
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("This assignment is closed"))
                })
        }
    }

    @Test func openAccessRecordsParticipationSoClosedReviewStaysReachable() async throws {
        try await withApp(app) { _ in
            // The durable mechanism: opening an assignment while it is open
            // records a participation row, which keeps it reachable once it
            // later closes — without depending on the on-disk working copy.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_participation"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Lifecycle"))
            let assignment = try await insertAssignment(
                testSetupID: setupID, title: "Lifecycle Lab", dueAt: nil, isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            let recorded = try await AssignmentParticipationStore.hasParticipation(
                userID: try user.requireID(), assignmentID: try assignment.requireID(), on: app.db)
            #expect(recorded, "Opening an assignment must record a durable participation row")

            // Close it (deadline now in the past) — the student must still reach it.
            assignment.dueAt = Date(timeIntervalSinceNow: -3600)
            try await assignment.save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .ok,
                        "A closed assignment stays reachable for a student who opened it while open")
                    #expect(res.body.string.contains("This assignment is closed"))
                })
        }
    }

    @Test func notebookSourceReturnsExistingWorkingCopy() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_source"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Original notebook"))

            let workingCopy = workingCopyPath(setupID: setupID, userID: try user.requireID())
            try FileManager.default.createDirectory(
                atPath: (workingCopy as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data(notebookJSON(markdown: "Saved working copy").utf8)
                .write(to: URL(fileURLWithPath: workingCopy))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentType?.description == "application/json; charset=utf-8")
                    #expect(res.body.string.contains("Saved working copy"))
                    #expect(res.body.string.contains("Original notebook") == false)
                })

        }
    }

    @Test func notebookPageSubmissionIDRestoresSelectedSubmission() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            let userID = try user.requireID()
            try await enroll(user)

            let setupID = "setup_nb_history"
            let submissionID = "sub_nb_history"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Instructor baseline"))
            _ = try await insertNotebookSubmission(
                id: submissionID,
                testSetupID: setupID,
                userID: userID,
                notebookJSON: notebookJSON(markdown: "History selection"),
                attemptNumber: 2
            )

            // Plant a stale working copy at the regular assignment path.
            // With the fix, viewing a submission must NOT overwrite this file —
            // the submission is written to a separate view-{submissionID}.ipynb path.
            let staleCopyPath = workingCopyPath(setupID: setupID, userID: userID)
            try FileManager.default.createDirectory(
                atPath: (staleCopyPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data(notebookJSON(markdown: "Stale working copy").utf8)
                .write(to: URL(fileURLWithPath: staleCopyPath))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?submissionID=\(submissionID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            // The submission-specific view file should contain the student's content.
            let userSlug = userID.uuidString.lowercased()
            let viewPath = publicDir + "jupyterlite/files/users/\(userSlug)/\(setupID)/view-\(submissionID).ipynb"
            let viewContent = try String(contentsOfFile: viewPath, encoding: .utf8)
            #expect(viewContent.contains("History selection"), "view file should contain submission content")

            // The regular working copy must be left untouched.
            let staleCopyAfter = try String(contentsOfFile: staleCopyPath, encoding: .utf8)
            #expect(staleCopyAfter.contains("Stale working copy"), "regular working copy must not be overwritten")

        }
    }

    @Test func notebookPageLinksSupportFilesAndLeavesStrayUserFilesAlone() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            let userID = try user.requireID()
            try await enroll(user)

            let setupID = "setup_nb_support"
            let manifest = """
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
                """
            _ = try await insertSetup(
                id: setupID,
                notebookJSON: notebookJSON(markdown: "Support seed"),
                manifest: manifest,
                zipEntries: [
                    ("assignment.ipynb", notebookJSON(markdown: "Support seed")),
                    ("test.sh", "#!/bin/sh\nexit 0\n"),
                    ("bmi.py", "def bmi():\n    return 22\n"),
                ]
            )

            let sharedDir = tmpDir + "testsetups/shared/\(setupID)/"
            try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
            try Data("def bmi():\n    return 22\n".utf8).write(
                to: URL(fileURLWithPath: sharedDir + "bmi.py")
            )

            let legacyRoots = [
                publicDir + "files/",
                publicDir + "jupyterlite/files/",
                publicDir + "jupyterlite/lab/files/",
                publicDir + "jupyterlite/notebooks/files/",
            ]
            for (index, root) in legacyRoots.enumerated() {
                let userDir = root + "users/\(userID.uuidString.lowercased())/"
                try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
                let filename = index.isMultiple(of: 2) ? "assignment.ipynb" : "sub_old.ipynb"
                try Data("legacy".utf8).write(to: URL(fileURLWithPath: userDir + filename))
            }

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            let studentDir = (workingCopyPath(setupID: setupID, userID: userID) as NSString).deletingLastPathComponent
            let supportPath = studentDir + "/bmi.py"
            #expect(FileManager.default.fileExists(atPath: supportPath))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: supportPath) == sharedDir + "bmi.py")
            #expect(FileManager.default.fileExists(atPath: studentDir + "/test.sh") == false)

            // Stray flat files in a user root are none of the page view's
            // business — nothing may delete them.  (The pre-0.5 boot sweep
            // that used to reclaim pre-v0.4 artifacts here was retired; any
            // remaining strays are inert.)
            for root in legacyRoots {
                let userDir = root + "users/\(userID.uuidString.lowercased())/"
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: userDir)) ?? []
                #expect(
                    contents.contains { $0.hasSuffix(".ipynb") },
                    "Page views must not delete stray user files from \(userDir)")
            }

            // The current per-setup working copy is present alongside them.
            #expect(FileManager.default.fileExists(atPath: workingCopyPath(setupID: setupID, userID: userID)))

        }
    }

    @Test func notebookSourceReplacesCorruptWorkingCopyWithLatestNotebookSubmission() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            let userID = try user.requireID()
            try await enroll(user)

            let setupID = "setup_nb_corrupt"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Instructor baseline"))
            _ = try await insertNotebookSubmission(
                id: "sub_nb_latest",
                testSetupID: setupID,
                userID: userID,
                notebookJSON: notebookJSON(markdown: "Recovered notebook"),
                attemptNumber: 3
            )

            let workingCopy = workingCopyPath(setupID: setupID, userID: userID)
            try FileManager.default.createDirectory(
                atPath: (workingCopy as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: URL(fileURLWithPath: workingCopy))

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Recovered notebook"))
                    #expect(res.body.string.contains("Instructor baseline") == false)
                })

            let replaced = try String(contentsOfFile: workingCopy, encoding: .utf8)
            #expect(replaced.contains("Recovered notebook"))
            #expect(replaced.contains("not json") == false)

        }
    }

    @Test func notebookPageRejectsHistorySelectionFromDifferentAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            let userID = try user.requireID()
            try await enroll(user)

            let setupID = "setup_nb_mismatch"
            let otherSetupID = "setup_nb_other"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Primary setup"))
            _ = try await insertSetup(id: otherSetupID, notebookJSON: notebookJSON(markdown: "Other setup"))
            _ = try await insertNotebookSubmission(
                id: "sub_nb_other_setup",
                testSetupID: otherSetupID,
                userID: userID,
                notebookJSON: notebookJSON(markdown: "Wrong assignment"),
                attemptNumber: 1
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_other_setup",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    @Test func notebookPageRejectsNonNotebookHistorySelection() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            let userID = try user.requireID()
            try await enroll(user)

            let setupID = "setup_nb_non_ipynb"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Instructor baseline"))

            let plainTextPath = tmpDir + "submissions/sub_nb_text.txt"
            try Data("hello world".utf8).write(to: URL(fileURLWithPath: plainTextPath))
            let submission = APISubmission(
                id: "sub_nb_text",
                testSetupID: setupID,
                zipPath: plainTextPath,
                attemptNumber: 1,
                status: "complete",
                filename: "sub_nb_text.txt",
                userID: userID,
                kind: APISubmission.Kind.student
            )
            try await submission.save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_text",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    @Test func notebookPageRejectsHistorySelectionOwnedByAnotherStudent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let otherCookie = try await loginAsStudent(username: "notebook_student_other")
            #expect(otherCookie.isEmpty == false)
            let fetchedOtherUser = try await APIUser.query(on: app.db)
                .filter(\.$username == "notebook_student_other")
                .first()
            let otherUser = try #require(fetchedOtherUser)
            try await enroll(otherUser)

            let setupID = "setup_nb_other_user"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Instructor baseline"))
            _ = try await insertNotebookSubmission(
                id: "sub_nb_other_user",
                testSetupID: setupID,
                userID: try otherUser.requireID(),
                notebookJSON: notebookJSON(markdown: "Other student's notebook"),
                attemptNumber: 1
            )

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_other_user",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func notebookPageReturns404WhenSetupHasNoStarterNotebook() async throws {
        try await withApp(app) { _ in
            // A setup with no .ipynb file (no notebookPath, zip contains only non-notebook
            // files) should return 404 rather than silently serving an empty notebook.
            // This prevents students from opening a blank notebook when the instructor
            // hasn't uploaded an assignment notebook yet.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_empty_seed"
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try makeZipAt(zipPath: zipPath, entries: [("readme.txt", "starter files pending")])

            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: zipPath,
                notebookPath: nil,
                courseID: try await makeCourse().requireID()
            )
            try await setup.save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    @Test func notebookSourceFallsBackToNestedManifestStarterNotebookWhenZipOnlySetupHasNoFlatNotebook() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_nested_manifest"
            let nestedNotebook = notebookJSON(markdown: "Nested manifest starter")
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try makeZipAt(
                zipPath: zipPath,
                entries: [
                    ("materials/starter.ipynb", nestedNotebook),
                    ("readme.txt", "nested zip"),
                ]
            )

            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,"starterNotebook":"starter.ipynb"}"#,
                zipPath: zipPath,
                notebookPath: nil,
                courseID: try await makeCourse().requireID()
            )
            try await setup.save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Nested manifest starter"))
                    #expect(res.body.string.contains("\"display_name\":\"Python (xeus-python)\""))
                })

        }
    }

    @Test func editorResetPageRendersConfirmForm() async throws {
        try await withApp(app) { _ in
            // GET /reset-editor renders the confirmation form (no clearing yet),
            // preserving a safe same-origin `next` and dropping an unsafe one.
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/reset-editor?next=/testsetups/abc/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains(#"action="/reset-editor""#))
                    #expect(html.contains("Reset editor"))
                    // Safe next echoed into the hidden field + Cancel link.
                    #expect(html.contains(#"value="/testsetups/abc/notebook""#))
                    // The confirm GET must NOT clear anything.
                    #expect(res.headers.first(name: "Clear-Site-Data") == nil)
                })
        }
    }

    @Test func editorResetPageSanitizesOpenRedirectNext() async throws {
        try await withApp(app) { _ in
            // An off-origin `next` must be neutralised to "/" so the page can't be
            // turned into an open redirect (or attribute injection).
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/reset-editor?next=https://evil.example.com/phish",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("evil.example.com") == false)
                    #expect(html.contains(#"value="/""#))
                })
        }
    }

    @Test func performEditorResetSetsClearSiteDataAndKeepsSession() async throws {
        try await withApp(app) { _ in
            // POST /reset-editor returns the "done" page AND a Clear-Site-Data
            // header that drops cache + storage (IndexedDB / service worker) but
            // NOT cookies — the student must stay logged in.
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/reset-editor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["_csrf": csrf, "next": "/testsetups/abc/notebook"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let clear = try #require(res.headers.first(name: "Clear-Site-Data"))
                    #expect(clear.contains("\"cache\""))
                    #expect(clear.contains("\"storage\""))
                    #expect(clear.contains("cookies") == false, "must not log the student out")
                    // The done page links back to the (safe) assignment.
                    #expect(res.body.string.contains(#"href="/testsetups/abc/notebook""#))
                })
        }
    }

    @Test func performEditorResetRequiresCSRF() async throws {
        try await withApp(app) { _ in
            // Without a CSRF token the POST is rejected (the auth group's CSRF
            // middleware) — a cross-origin page can't silently wipe a student's
            // in-progress notebook.
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .POST, "/reset-editor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["next": "/"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                    #expect(res.headers.first(name: "Clear-Site-Data") == nil)
                })
        }
    }

    @Test func notebookSourceFallsBackToFirstNestedNotebookWhenZipOnlySetupHasNoManifestStarter() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_nested_first"
            let nestedNotebook = notebookJSON(markdown: "First nested notebook")
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try makeZipAt(
                zipPath: zipPath,
                entries: [
                    ("nested/assignment.ipynb", nestedNotebook),
                    ("nested/support.py", "value = 1"),
                ]
            )

            let setup = APITestSetup(
                id: setupID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
                zipPath: zipPath,
                notebookPath: nil,
                courseID: try await makeCourse().requireID()
            )
            try await setup.save(on: app.db)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("First nested notebook"))
                    #expect(res.body.string.contains("\"display_name\":\"Python (xeus-python)\""))
                })

        }
    }
}
