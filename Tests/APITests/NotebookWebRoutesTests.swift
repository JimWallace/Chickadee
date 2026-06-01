import Fluent
import Foundation
import Testing
import XCTVapor

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
        let enrollment = APICourseEnrollment(
            userID: try user.requireID(),
            courseID: try course.requireID()
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
                    #expect(html.contains("data-notebook-url=\"/testsetups/\(setupID)/notebook/source\""))
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
                        XCTFail("Expected data-working-copy-mtime=\"<int>\" attribute on iframe"); return
                    }
                    XCTAssertGreaterThan(mtime, 0, "Working-copy mtime should be a positive Unix-epoch timestamp")
                })

            let workingCopy = try String(
                contentsOfFile: workingCopyPath(setupID: setupID, userID: try user.requireID()),
                encoding: .utf8
            )
            #expect(workingCopy.contains("Notebook seed"))
            #expect(workingCopy.contains("\"display_name\":\"Python (Pyodide)\""))

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

    @Test func notebookPageClosedAssignmentNeverOpenedRedirectsToDashboard() async throws {
        try await withApp(app) { _ in
            // A student who has never opened a closed assignment (no working
            // copy, no submission) is redirected to their dashboard instead of
            // seeing the notebook — this keeps pre-posted links from spoiling
            // not-yet-opened labs.
            let cookie = try await loginAsStudent()
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_closed_unopened"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Hidden"))
            _ = try await insertAssignment(
                testSetupID: setupID,
                title: "Unopened Closed Lab",
                dueAt: Date(timeIntervalSinceNow: -3600),
                isOpen: true
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

    @Test func notebookPageLinksSupportFilesAndRemovesLegacyNotebookCopies() async throws {
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

            for root in legacyRoots {
                let userDir = root + "users/\(userID.uuidString.lowercased())/"
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: userDir)) ?? []
                #expect(
                    contents.contains { $0.hasSuffix(".ipynb") } == false,
                    "Legacy notebooks should be removed from \(userDir)")
            }

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
                    #expect(res.body.string.contains("\"display_name\":\"Python (Pyodide)\""))
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
                    #expect(res.body.string.contains("\"display_name\":\"Python (Pyodide)\""))
                })

        }
    }
}
