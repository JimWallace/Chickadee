import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The app and the helpers shared by the `NotebookWebRoutes*Tests` suites,
/// which were one 2,300-line suite until they were split along its sections.
/// Each suite stores what `makeNotebookWebRoutesApp()` returns and conforms
/// to this protocol, so every test body reads exactly as it did before.
protocol NotebookWebRoutesFixture {
    var app: Application { get }
    var tmpDir: String { get }
    var publicDir: String { get }
}

/// Builds the app the notebook web-route suites share: a working directory of
/// its own (with the repository `Resources` linked in), so the JupyterLite
/// working copies land under a per-test `Public/` tree.
func makeNotebookWebRoutesApp() async throws -> (app: Application, tmpDir: String, publicDir: String) {
    let tmpRoot =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("chickadee-notebook-web-\(UUID().uuidString)")
        .path + "/"
    var publicDir = ""

    let application = try await makeTestingApplication { app in
        app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
        publicDir = app.directory.publicDirectory
        // Seeded so that the app does not read the configuration of the
        // machine that runs the tests, as `makeTestApp` does.
        app.appConfig = AppConfig.testDefaults()

        try FileManager.default.createDirectory(
            atPath: tmpRoot, withIntermediateDirectories: true)
        // Recorded so the per-test `withApp` teardown removes the tree —
        // one survived per test before #1298 (the `Resources` symlink
        // inside is removed as a link, its target untouched).
        app.testDataDirectory = tmpRoot
        try FileManager.default.createSymbolicLink(
            atPath: tmpRoot + "Resources",
            withDestinationPath: repositoryRoot.appendingPathComponent("Resources").path
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

        // The three registrations that `makeTestApp` adds, for the same
        // reasons it gives. This suite cannot use `makeTestApp`, because
        // it needs a working directory of its own.
        app.middleware.use(AssignmentVersionCaptureMiddleware())
        app.lifecycle.use(DataExportDrainLifecycleHandler())
        app.kernelEnvironments = KernelEnvironments.load(
            publicDirectory: app.directory.publicDirectory)

        try routes(app)
    }

    return (application, tmpRoot, publicDir)
}

extension NotebookWebRoutesFixture {
    func studentUser() async throws -> APIUser {
        let user = try await APIUser.query(on: app.db)
            .filter(\.$username == "notebook_student")
            .first()
        return try #require(user)
    }

    func makeCourse() async throws -> APICourse {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "NOTE185").first() {
            return existing
        }
        return try await makeTestCourse(on: app, code: "NOTE185", name: "Notebook Coverage")
    }

    func enroll(_ user: APIUser) async throws {
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
    func insertSetup(
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
        try await writeZipFixture(at: zipPath, entries: entries.map { ($0.0, $0.1) })
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
    func insertAssignment(
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
            visibility: isOpen ? .open : .closed,
            courseID: try await makeCourse().requireID()
        )
        try await assignment.save(on: app.db)
        return assignment
    }

    @discardableResult
    func insertNotebookSubmission(
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

    func workingCopyPath(setupID: String, userID: UUID) -> String {
        publicDir + "jupyterlite/files/" + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
    }

    func notebookJSON(markdown: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":[\(markdown.debugDescription)]}]}
        """
    }

    /// Single-code-cell notebook — personalization substitution only rewrites
    /// code cells, so `{{name}}` fixtures need this shape.
    func notebookJSON(code: String) -> String {
        """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":[\(code.debugDescription)]}]}
        """
    }

    /// Drives the editor's "Save to assignment" endpoint with `body` as the
    /// notebook JSON, mirroring what `notebook.js` sends (JSON body + the CSRF
    /// token in a header).
    func postNotebookSave(
        setupID: String,
        cookie: String,
        file: String? = nil,
        view: String? = nil,
        extraCookie: String? = nil,
        body: String,
        afterResponse: (TestResponse) throws -> Void
    ) async throws {
        let (csrf, session) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        let sessionCookie = extraCookie.map { session + "; " + $0 } ?? session
        let params = [file.map { "file=\($0)" }, view.map { "view=\($0)" }].compactMap(\.self)
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

    func staffCookie(username: String) async throws -> String {
        let cookie = try await loginUser(
            username: username, password: "testpassword", role: "instructor", on: app)
        let staff = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await enroll(staff)
        return cookie
    }
}
