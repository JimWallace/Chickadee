// Tests/APITests/Notebooks/NotebookWorkingCopyStoreGapTests.swift
//
// The rules in `NotebookWorkingCopyStore` that the coverage report showed no
// test for. The store holds each student's notebook in progress, so each
// test here pins a refusal, a fallback or a refresh decision that decides
// which bytes a viewer opens:
//
// - a refreshed copy that is unchanged apart from its outputs is kept, and a
//   changed one is rewritten;
// - a template view seeds from the stored starter, not from the viewer's own
//   submission;
// - a submission that is not a notebook is passed over for the seed;
// - personalization falls back to the seed bytes, or to literal values only,
//   and logs why;
// - opening a past submission refuses an unknown ID, a submission that is not
//   a student's, and an artifact that is not a notebook.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct NotebookWorkingCopyStoreGapTests {

    private static let plainManifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}
        """

    private static let literalManifest = """
        {"schemaVersion":1,"language":"python","languageDeclared":true,"requiredFiles":[],"testSuites":[],\
        "timeLimitSeconds":10,"globalVariables":[{"name":"cap","value":5}]}
        """

    private static let expressionManifest = """
        {"schemaVersion":1,"language":"python","languageDeclared":true,"requiredFiles":[],"testSuites":[],\
        "timeLimitSeconds":10,"globalVariables":[{"name":"cap","value":5}],\
        "globalExpressions":[{"name":"offset","expression":"seed % 3"}]}
        """

    /// A one-cell notebook. `outputs` and `count` let a test give the cell the
    /// residue of a run, which the refresh comparison must ignore.
    private static func notebook(source: String, outputs: String = "[]", count: String = "null") -> Data {
        Data(
            """
            {"cells":[{"cell_type":"code","execution_count":\(count),"metadata":{},"outputs":\(outputs),\
            "source":[\(source.debugDescription)]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """.utf8)
    }

    private static let streamOutput =
        #"[{"name":"stdout","output_type":"stream","text":["42\n"]}]"#

    /// Points the app's public directory into its own temp tree, so a working
    /// copy never lands in the repository's `Public/`.
    private func usePrivatePublicDirectory(_ app: Application) throws {
        let root = app.testSetupsDirectory + "wd/"
        app.directory = DirectoryConfiguration(workingDirectory: root)
        try FileManager.default.createDirectory(
            atPath: app.directory.publicDirectory, withIntermediateDirectories: true)
    }

    private func workingCopyPath(_ app: Application, _ relativePath: String) -> String {
        app.directory.publicDirectory + "jupyterlite/files/" + relativePath
    }

    private func writeWorkingCopy(_ data: Data, app: Application, relativePath: String) throws {
        let path = workingCopyPath(app, relativePath)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - workingCopyMtimeEpoch

    @Test func theMtimeOfAMissingWorkingCopyIsZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-no-copy-\(UUID().uuidString).ipynb").path
        #expect(workingCopyMtimeEpoch(absolutePath: missing) == 0)
    }

    // MARK: - refreshFromSeed

    /// A copy that matches the seed apart from the outputs of a run is kept
    /// as it is. Rewriting it would drop the outputs and move the mtime, and
    /// the editor would then reload over its in-browser edits.
    @Test func aRefreshKeepsACopyThatDiffersOnlyInItsOutputs() async throws {
        try await withTestApp(prefix: "chickadee-wc-keep") { app in
            try usePrivatePublicDirectory(app)
            let course = try await makeTestCourse(on: app, code: "WCK101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_keep", courseID: try course.requireID(),
                manifest: Self.plainManifest, withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_keep_staff")
            let userID = try user.requireID()
            let relativePath = "users/\(userID.uuidString.lowercased())/setup_wc_keep/solution.ipynb"

            let seed = Self.notebook(source: "print(42)")
            let runCopy = Self.notebook(source: "print(42)", outputs: Self.streamOutput, count: "3")
            try writeWorkingCopy(runCopy, app: app, relativePath: relativePath)

            let opened = try await ensureUserNotebookWorkingCopy(
                setupID: "setup_wc_keep", userID: userID, fallbackSetup: setup,
                relativePath: relativePath, defaultData: seed, refreshFromSeed: true,
                on: app.db, application: app, logger: app.logger)

            #expect(opened == runCopy, "The copy with its outputs is returned")
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: workingCopyPath(app, relativePath)))
            #expect(onDisk == runCopy, "The copy on disk is not rewritten")
        }
    }

    /// A copy whose cells differ from the seed is a stale view of the stored
    /// notebook, and a refresh replaces it.
    @Test func aRefreshRewritesACopyWhoseCellsChanged() async throws {
        try await withTestApp(prefix: "chickadee-wc-rewrite") { app in
            try usePrivatePublicDirectory(app)
            let course = try await makeTestCourse(on: app, code: "WCR101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_rewrite", courseID: try course.requireID(),
                manifest: Self.plainManifest, withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_rewrite_staff")
            let userID = try user.requireID()
            let relativePath = "users/\(userID.uuidString.lowercased())/setup_wc_rewrite/solution.ipynb"

            try writeWorkingCopy(Self.notebook(source: "print(1)"), app: app, relativePath: relativePath)
            let seed = Self.notebook(source: "print(2)")

            let opened = try await ensureUserNotebookWorkingCopy(
                setupID: "setup_wc_rewrite", userID: userID, fallbackSetup: setup,
                relativePath: relativePath, defaultData: seed, refreshFromSeed: true,
                on: app.db, application: app, logger: app.logger)

            #expect(opened == seed)
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: workingCopyPath(app, relativePath)))
            #expect(onDisk == seed)
        }
    }

    // MARK: - Seed selection

    /// A template copy is a view of the assignment. An author who also
    /// submitted must open the stored starter, not their submission, or a
    /// save would put the submission over the class's starter.
    @Test func aTemplateViewSeedsFromTheStarterAndNotFromASubmission() async throws {
        try await withTestApp(prefix: "chickadee-wc-template") { app in
            let course = try await makeTestCourse(on: app, code: "WCT101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_template", courseID: try course.requireID(),
                manifest: Self.plainManifest, withZip: false)
            let starter = Self.notebook(source: "x = starter_value")
            try starter.write(to: URL(fileURLWithPath: try #require(setup.notebookPath)))
            let user = try await makeTestUser(on: app, username: "wc_template_author")
            let userID = try user.requireID()
            let submission = try await makeTestSubmission(
                on: app, id: "sub_wc_template", setupID: "setup_wc_template", userID: userID)
            let submitted = Self.notebook(source: "x = submitted_value")
            try submitted.write(to: URL(fileURLWithPath: submission.zipPath))

            func seed(_ mode: NotebookViewMode) async throws -> Data {
                try await workingCopySeedData(
                    WorkingCopySeedSource(
                        setupID: "setup_wc_template", userID: userID, setup: setup, defaultData: nil,
                        viewMode: mode),
                    on: app.db, application: app, logger: app.logger)
            }

            let template = try #require(String(data: try await seed(.template), encoding: .utf8))
            #expect(template.contains("x = starter_value"))
            #expect(!template.contains("submitted_value"))
            #expect(try await seed(.personalized) == submitted, "The rendered view still opens the submission")
        }
    }

    /// Only a notebook submission can seed a working copy. A file submitted
    /// under another extension is passed over, even when its bytes parse as
    /// JSON, and the seed falls back to the starter.
    @Test func aSubmissionThatIsNotANotebookIsPassedOver() async throws {
        try await withTestApp(prefix: "chickadee-wc-zipsub") { app in
            let course = try await makeTestCourse(on: app, code: "WCZ101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_zipsub", courseID: try course.requireID(),
                manifest: Self.plainManifest, withZip: false)
            let starter = Self.notebook(source: "x = starter_value")
            try starter.write(to: URL(fileURLWithPath: try #require(setup.notebookPath)))
            let user = try await makeTestUser(on: app, username: "wc_zipsub_student")
            let userID = try user.requireID()

            let zipPath = app.submissionsDirectory + "sub_wc_zipsub.zip"
            try Self.notebook(source: "x = zip_value").write(to: URL(fileURLWithPath: zipPath))
            try await APISubmission(
                id: "sub_wc_zipsub", testSetupID: "setup_wc_zipsub", zipPath: zipPath, attemptNumber: 1,
                status: "complete", filename: "work.zip", userID: userID, kind: APISubmission.Kind.student
            ).save(on: app.db)

            let seeded = try await workingCopySeedData(
                WorkingCopySeedSource(
                    setupID: "setup_wc_zipsub", userID: userID, setup: setup, defaultData: nil,
                    viewMode: .personalized),
                on: app.db, application: app, logger: app.logger)
            let text = try #require(String(data: seeded, encoding: .utf8))
            #expect(text.contains("x = starter_value"))
            #expect(!text.contains("zip_value"))
        }
    }

    // MARK: - Personalization fallbacks

    private func personalizedSeed(
        app: Application, setup: APITestSetup, userID: UUID, data: Data, logger: Logger
    ) async throws -> Data {
        try await workingCopySeedData(
            WorkingCopySeedSource(
                setupID: try setup.requireID(), userID: userID, setup: setup, defaultData: data,
                viewMode: .personalized),
            on: app.db, application: app, logger: logger)
    }

    /// A manifest that does not decode leaves the seed as it is: the student
    /// still opens a notebook.
    @Test func aManifestThatDoesNotDecodeLeavesTheSeedUnchanged() async throws {
        try await withTestApp(prefix: "chickadee-wc-badmanifest") { app in
            let course = try await makeTestCourse(on: app, code: "WCM101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_badmanifest", courseID: try course.requireID(),
                manifest: "not a manifest", withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_badmanifest_student")
            let seed = Self.notebook(source: "cap = {{cap}}")

            let result = try await personalizedSeed(
                app: app, setup: setup, userID: try user.requireID(), data: seed, logger: app.logger)
            #expect(result == seed)
        }
    }

    /// A seed that is not a notebook makes the substitution fail. The seed
    /// bytes come back unchanged, and the failure is logged.
    @Test func aSubstitutionFailureFallsBackToTheSeedBytes() async throws {
        try await withTestApp(prefix: "chickadee-wc-substfail") { app in
            let course = try await makeTestCourse(on: app, code: "WCS101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_substfail", courseID: try course.requireID(),
                manifest: Self.literalManifest, withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_substfail_student")
            let capture = WorkingCopyLogCapture()
            let seed = Data("[1, 2, 3]".utf8)

            let result = try await personalizedSeed(
                app: app, setup: setup, userID: try user.requireID(), data: seed, logger: capture.logger)

            #expect(result == seed)
            #expect(
                capture.messages(containing: "Notebook substitution failed for setup setup_wc_substfail").count == 1)
        }
    }

    /// Expressions need a per-student seed, and a setup with no assignment
    /// has none. The literal values are still substituted, the expression's
    /// placeholder stays, and the missing seed is logged.
    @Test func expressionsWithNoSeedSubstituteLiteralValuesOnly() async throws {
        try await withTestApp(prefix: "chickadee-wc-noseed") { app in
            let course = try await makeTestCourse(on: app, code: "WCN101")
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_noseed", courseID: try course.requireID(),
                manifest: Self.expressionManifest, withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_noseed_student")
            let capture = WorkingCopyLogCapture()
            let seed = Self.notebook(source: "cap = {{cap}}\noffset = {{offset}}")

            let result = try await personalizedSeed(
                app: app, setup: setup, userID: try user.requireID(), data: seed, logger: capture.logger)

            let text = try #require(String(data: result, encoding: .utf8))
            #expect(text.contains("cap = 5"))
            #expect(text.contains("offset = {{offset}}"))
            #expect(capture.messages(containing: "Could not resolve a seed for setup setup_wc_noseed").count == 1)
        }
    }

    // MARK: - notebookDataForHistorySelection

    @Test func openingAnUnknownSubmissionIsNotFound() async throws {
        try await withTestApp(prefix: "chickadee-wc-hist-missing") { app in
            let user = try await makeTestUser(on: app, username: "wc_hist_missing")
            await #expect {
                _ = try await notebookDataForHistorySelection(
                    caller: user, submissionID: "sub_does_not_exist", setupID: "setup_any",
                    userID: try user.requireID(), on: app.db)
            } throws: { error in
                guard case AppError.notFound(let resource) = error else { return false }
                return resource == "Submission"
            }
        }
    }

    /// Only a student's own submission opens in the notebook view. A
    /// validation run is refused, even for the account that made it.
    @Test func aSubmissionThatIsNotAStudentsIsRefused() async throws {
        try await withTestApp(prefix: "chickadee-wc-hist-kind") { app in
            let course = try await makeTestCourse(on: app, code: "WCH101")
            try await makeTestSetup(
                on: app, id: "setup_wc_hist_kind", courseID: try course.requireID(),
                manifest: Self.plainManifest, withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_hist_kind")
            let userID = try user.requireID()
            try await makeTestSubmission(
                on: app, id: "sub_wc_hist_kind", setupID: "setup_wc_hist_kind", userID: userID,
                kind: APISubmission.Kind.validation)

            await #expect {
                _ = try await notebookDataForHistorySelection(
                    caller: user, submissionID: "sub_wc_hist_kind", setupID: "setup_wc_hist_kind",
                    userID: userID, on: app.db)
            } throws: { error in
                guard case AppError.forbidden = error else { return false }
                return true
            }
        }
    }

    /// A notebook submission whose stored file does not parse is reported as
    /// missing, not handed to the editor.
    @Test func aNotebookArtifactThatDoesNotParseIsNotFound() async throws {
        try await withTestApp(prefix: "chickadee-wc-hist-garbage") { app in
            let course = try await makeTestCourse(on: app, code: "WCG101")
            try await makeTestSetup(
                on: app, id: "setup_wc_hist_garbage", courseID: try course.requireID(),
                manifest: Self.plainManifest, withZip: false)
            let user = try await makeTestUser(on: app, username: "wc_hist_garbage")
            let userID = try user.requireID()
            let submission = try await makeTestSubmission(
                on: app, id: "sub_wc_hist_garbage", setupID: "setup_wc_hist_garbage", userID: userID)
            try Data("this is not json".utf8).write(to: URL(fileURLWithPath: submission.zipPath))

            await #expect {
                _ = try await notebookDataForHistorySelection(
                    caller: user, submissionID: "sub_wc_hist_garbage", setupID: "setup_wc_hist_garbage",
                    userID: userID, on: app.db)
            } throws: { error in
                guard case AppError.notFound(let resource) = error else { return false }
                return resource == "Notebook artifact for this submission"
            }
        }
    }
}
