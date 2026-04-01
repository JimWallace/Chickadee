import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation

final class NotebookWebRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpRoot: String!
    private var tmpDir: String!
    private var publicDir: String!
    private var repoRoot: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        repoRoot = FileManager.default.currentDirectoryPath
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-notebook-web-\(UUID().uuidString)")
            .path + "/"
        tmpDir = tmpRoot
        app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
        publicDir = app.directory.publicDirectory

        try FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: tmpRoot + "Resources",
            withDestinationPath: repoRoot + "/Resources"
        )
        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)

        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpRoot)
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
        return try XCTUnwrap(user)
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
        let storedManifest = manifest ?? """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """
        let zipPath = tmpDir + "testsetups/\(id).zip"
        let notebookPath = tmpDir + "testsetups/\(id).ipynb"
        let entries = zipEntries.isEmpty ? [("assignment.ipynb", notebookJSON)] : zipEntries
        try makeZipAt(zipPath: zipPath, entries: entries)
        try notebookJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: notebookPath))

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
    private func insertAssignment(testSetupID: String, title: String) async throws -> APIAssignment {
        let assignment = APIAssignment(
            testSetupID: testSetupID,
            title: title,
            dueAt: nil,
            isOpen: true,
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
        try notebookJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
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
            throw XCTSkip("env not available")
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
            throw XCTSkip("python3 not available or failed to create zip")
        }
    }

    func testNotebookPageSeedsWorkingCopyAndRendersEditorFrame() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enroll(user)

        let setupID = "setup_nb_page"
        let seedNotebook = notebookJSON(markdown: "Notebook seed")
        _ = try await insertSetup(id: setupID, notebookJSON: seedNotebook)
        _ = try await insertAssignment(testSetupID: setupID, title: "Notebook Lab")

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("data-setup-id=\"\(setupID)\""))
            XCTAssertTrue(html.contains("data-notebook-url=\"/testsetups/\(setupID)/notebook/source\""))
            XCTAssertTrue(html.contains("/jupyterlite/notebooks/index.html?workspace=\(setupID)-"))
            XCTAssertTrue(html.contains("&amp;path=users/"))
        })

        let workingCopy = try String(
            contentsOfFile: workingCopyPath(setupID: setupID, userID: try user.requireID()),
            encoding: .utf8
        )
        XCTAssertTrue(workingCopy.contains("Notebook seed"))
        XCTAssertTrue(workingCopy.contains("\"display_name\":\"Python (Pyodide)\""))
    }

    func testNotebookSourceReturnsExistingWorkingCopy() async throws {
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
        try notebookJSON(markdown: "Saved working copy")
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: workingCopy))

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook/source", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.description, "application/json; charset=utf-8")
            XCTAssertTrue(res.body.string.contains("Saved working copy"))
            XCTAssertFalse(res.body.string.contains("Original notebook"))
        })
    }

    func testNotebookPageSubmissionIDRestoresSelectedSubmission() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await enroll(user)

        let setupID = "setup_nb_history"
        _ = try await insertSetup(id: setupID, notebookJSON: notebookJSON(markdown: "Instructor baseline"))
        _ = try await insertNotebookSubmission(
            id: "sub_nb_history",
            testSetupID: setupID,
            userID: userID,
            notebookJSON: notebookJSON(markdown: "History selection"),
            attemptNumber: 2
        )

        let staleCopyPath = workingCopyPath(setupID: setupID, userID: userID)
        try FileManager.default.createDirectory(
            atPath: (staleCopyPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try notebookJSON(markdown: "Stale working copy")
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: staleCopyPath))

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_history", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let restored = try String(contentsOfFile: staleCopyPath, encoding: .utf8)
        XCTAssertTrue(restored.contains("History selection"))
        XCTAssertFalse(restored.contains("Stale working copy"))
    }

    func testNotebookPageLinksSupportFilesAndRemovesLegacyNotebookCopies() async throws {
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
                ("bmi.py", "def bmi():\n    return 22\n")
            ]
        )

        let sharedDir = tmpDir + "testsetups/shared/\(setupID)/"
        try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        try "def bmi():\n    return 22\n".data(using: .utf8)!.write(
            to: URL(fileURLWithPath: sharedDir + "bmi.py")
        )

        let legacyRoots = [
            publicDir + "files/",
            publicDir + "jupyterlite/files/",
            publicDir + "jupyterlite/lab/files/",
            publicDir + "jupyterlite/notebooks/files/"
        ]
        for (index, root) in legacyRoots.enumerated() {
            let userDir = root + "users/\(userID.uuidString.lowercased())/"
            try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
            let filename = index.isMultiple(of: 2) ? "assignment.ipynb" : "sub_old.ipynb"
            try Data("legacy".utf8).write(to: URL(fileURLWithPath: userDir + filename))
        }

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let studentDir = (workingCopyPath(setupID: setupID, userID: userID) as NSString).deletingLastPathComponent
        let supportPath = studentDir + "/bmi.py"
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportPath))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: supportPath),
            sharedDir + "bmi.py"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: studentDir + "/test.sh"))

        for root in legacyRoots {
            let userDir = root + "users/\(userID.uuidString.lowercased())/"
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: userDir)) ?? []
            XCTAssertFalse(contents.contains { $0.hasSuffix(".ipynb") }, "Legacy notebooks should be removed from \(userDir)")
        }
    }

    func testNotebookSourceReplacesCorruptWorkingCopyWithLatestNotebookSubmission() async throws {
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

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook/source", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("Recovered notebook"))
            XCTAssertFalse(res.body.string.contains("Instructor baseline"))
        })

        let replaced = try String(contentsOfFile: workingCopy, encoding: .utf8)
        XCTAssertTrue(replaced.contains("Recovered notebook"))
        XCTAssertFalse(replaced.contains("not json"))
    }

    func testNotebookPageRejectsHistorySelectionFromDifferentAssignment() async throws {
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

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_other_setup", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testNotebookPageRejectsNonNotebookHistorySelection() async throws {
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

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_text", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testNotebookPageRejectsHistorySelectionOwnedByAnotherStudent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enroll(user)

        let otherCookie = try await loginAsStudent(username: "notebook_student_other")
        XCTAssertFalse(otherCookie.isEmpty)
        let fetchedOtherUser = try await APIUser.query(on: app.db)
            .filter(\.$username == "notebook_student_other")
            .first()
        let otherUser = try XCTUnwrap(fetchedOtherUser)
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

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook?submissionID=sub_nb_other_user", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testNotebookPageReturns404WhenSetupHasNoStarterNotebook() async throws {
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
            manifest: #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
            zipPath: zipPath,
            notebookPath: nil,
            courseID: try await makeCourse().requireID()
        )
        try await setup.save(on: app.db)

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook/source", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testNotebookSourceFallsBackToNestedManifestStarterNotebookWhenZipOnlySetupHasNoFlatNotebook() async throws {
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
                ("readme.txt", "nested zip")
            ]
        )

        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,"starterNotebook":"starter.ipynb"}"#,
            zipPath: zipPath,
            notebookPath: nil,
            courseID: try await makeCourse().requireID()
        )
        try await setup.save(on: app.db)

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook/source", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("Nested manifest starter"))
            XCTAssertTrue(res.body.string.contains("\"display_name\":\"Python (Pyodide)\""))
        })
    }

    func testNotebookSourceFallsBackToFirstNestedNotebookWhenZipOnlySetupHasNoManifestStarter() async throws {
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
                ("nested/support.py", "value = 1")
            ]
        )

        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
            zipPath: zipPath,
            notebookPath: nil,
            courseID: try await makeCourse().requireID()
        )
        try await setup.save(on: app.db)

        try await app.asyncTest(.GET, "/testsetups/\(setupID)/notebook/source", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("First nested notebook"))
            XCTAssertTrue(res.body.string.contains("\"display_name\":\"Python (Pyodide)\""))
        })
    }
}
