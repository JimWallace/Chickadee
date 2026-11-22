import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The notebook page and source routes: staff controls, reset, submission
/// history, the editor reset page and the starter-notebook fallbacks. The
/// other sections of this suite are the `NotebookWebRoutes*Tests` files beside it.
@Suite(.serialized) final class NotebookWebRoutesTests: NotebookWebRoutesFixture {

    let tmpDir: String
    let publicDir: String

    let app: Application

    init() async throws {
        let fixture = try await makeNotebookWebRoutesApp()
        self.app = fixture.app
        self.tmpDir = fixture.tmpDir
        self.publicDir = fixture.publicDir
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
                .GET, "/testsetups/\(setupID)/notebook?edit=1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffLogin) },
                afterResponse: { res in
                    #expect(res.body.string.contains(#"id="nb-save-assignment""#))
                })

            let studentLogin = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
                atPath: URL(fileURLWithPath: copyPath).deletingLastPathComponent().path,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
                atPath: URL(fileURLWithPath: copyPath).deletingLastPathComponent().path,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_source"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Original notebook"))

            let workingCopy = workingCopyPath(setupID: setupID, userID: try user.requireID())
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: workingCopy).deletingLastPathComponent().path,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
                atPath: URL(fileURLWithPath: staleCopyPath).deletingLastPathComponent().path,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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

            let studentDir = URL(fileURLWithPath: workingCopyPath(setupID: setupID, userID: userID))
                .deletingLastPathComponent().path
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
                atPath: URL(fileURLWithPath: workingCopy).deletingLastPathComponent().path,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let otherCookie = try await loginAsStudent("notebook_student_other", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_empty_seed"
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try await writeZipFixture(at: zipPath, entries: [("readme.txt", "starter files pending")])

            let setup = APITestSetup(
                id: setupID,
                manifest:
                    TestManifests.workerEmptyExplicit,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_nested_manifest"
            let nestedNotebook = notebookJSON(markdown: "Nested manifest starter")
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try await writeZipFixture(
                at: zipPath,
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
            let cookie = try await loginAsStudent("notebook_student", on: app)

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
            let cookie = try await loginAsStudent("notebook_student", on: app)

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
            let cookie = try await loginAsStudent("notebook_student", on: app)
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
            let cookie = try await loginAsStudent("notebook_student", on: app)

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
            let cookie = try await loginAsStudent("notebook_student", on: app)
            let user = try await studentUser()
            try await enroll(user)

            let setupID = "setup_nb_nested_first"
            let nestedNotebook = notebookJSON(markdown: "First nested notebook")
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try await writeZipFixture(
                at: zipPath,
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

    /// A setup ID that names no setup is a 404 on each notebook route, before
    /// any enrollment or gate check.
    @Test func everyNotebookRouteAnswersNotFoundForAnUnknownSetup() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            for path in ["notebook", "notebook/source", "solution/download"] {
                try await app.asyncTest(
                    .GET, "/testsetups/setup_nb_missing/\(path)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in #expect(res.status == .notFound, "\(path)") })
            }
            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/setup_nb_missing/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    /// A bare setup with no assignment row is not a student-facing
    /// assignment, so the self-reset refuses it as not found.
    @Test func resetOwnNotebookRefusesASetupWithNoAssignment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            try await enroll(try await studentUser())
            let setupID = "setup_nb_reset_bare"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Bare"))

            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    /// An open assignment whose setup has no notebook has nothing to reset to.
    @Test func resetOwnNotebookWithoutAStarterIsABadRequest() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            try await enroll(try await studentUser())
            let setupID = "setup_nb_reset_no_starter"
            let zipPath = tmpDir + "testsetups/\(setupID).zip"
            try await writeZipFixture(at: zipPath, entries: [("readme.txt", "no notebook")])
            try await APITestSetup(
                id: setupID, manifest: TestManifests.workerEmptyExplicit, zipPath: zipPath,
                notebookPath: nil, courseID: try await makeCourse().requireID()
            ).save(on: app.db)
            _ = try await insertAssignment(testSetupID: setupID, title: "No Starter Lab", isOpen: true)

            let (csrf, sessionCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .badRequest) })
        }
    }

    /// The raw source route applies the page's closed-assignment gate: a
    /// student who never opened a closed assignment cannot fetch its starter.
    @Test func notebookSourceRefusesAClosedAssignmentTheStudentNeverOpened() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("notebook_student", on: app)
            try await enroll(try await studentUser())
            let setupID = "setup_nb_source_closed"
            _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Closed starter"))
            _ = try await insertAssignment(
                testSetupID: setupID, title: "Closed Source Lab",
                dueAt: Date(timeIntervalSinceNow: -3600), isOpen: true)

            try await app.asyncTest(
                .GET, "/testsetups/\(setupID)/notebook/source",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                    #expect(res.body.string.contains("Closed starter") == false)
                })
        }
    }
}
