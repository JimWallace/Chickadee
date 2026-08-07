// Tests/APITests/SubmissionModeRoutesTests.swift
//
// The upload submission mode, end to end on the web surface:
//
//   * the accept-attribute derivation (from the one language table — the
//     hand-listed predecessor had gone stale twice),
//   * suite rebuilds preserving submissionMode + requiredFiles (the
//     fresh-dict `makeWorkerManifestJSON` loses anything not threaded),
//   * the two-way authoring refusal of the upload + browser combination,
//   * the student-facing redirect: an upload assignment's notebook URL (the
//     vanity link lands there) sends students to the upload form,
//   * the submit page's required-files hint,
//   * and the edit-save path persisting a mode change / refusing a bad one.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct SubmissionModeRoutesTests {

    static let uploadManifest = """
        {"schemaVersion":1,"gradingMode":"worker","submissionMode":"uploadOnly","requiredFiles":["main.cpp","util.h"],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let browserManifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let sampleNotebookJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[],"execution_count":null}]}
        """

    // MARK: - Accept-attribute derivation (pure)

    @Test func acceptAttributeDerivesFromTheLanguageTable() {
        // Every assignment language's extensions plus the two formats every
        // assignment takes.  Adding a fifth language changes this string
        // without anyone editing a template.
        #expect(submissionAcceptAttribute(manifest: nil) == ".ipynb,.lua,.m,.py,.r,.zip")
    }

    @Test func acceptAttributeIncludesRequiredFileExtensions() throws {
        let manifest = try JSONDecoder().decode(
            TestProperties.self, from: Data(Self.uploadManifest.utf8))
        // `.cpp` and `.h` come from requiredFiles — extensions no
        // AssignmentLanguage claims, which is the upload-mode C++ case.
        #expect(
            submissionAcceptAttribute(manifest: manifest)
                == ".cpp,.h,.ipynb,.lua,.m,.py,.r,.zip")
    }

    @Test func acceptAttributeSkipsExtensionlessRequiredFiles() throws {
        let json = """
            {"schemaVersion":1,"requiredFiles":["Makefile","main.cpp"]}
            """
        let manifest = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        let accept = submissionAcceptAttribute(manifest: manifest)
        #expect(accept.contains(".cpp"))
        #expect(!accept.contains("Makefile"))
    }

    // MARK: - Suite rebuilds preserve the new fields (pure)

    @Test func suiteRebuildPreservesSubmissionModeAndRequiredFiles() throws {
        let added = try #require(
            updateManifestAddingScript(
                manifestJSON: Self.uploadManifest,
                entry: ConfiguredSuiteEntry(
                    script: "secrettest_extra.sh", tier: "secret", order: 2,
                    dependsOn: [], points: 1, displayName: nil)))
        let afterAdd = try JSONDecoder().decode(TestProperties.self, from: Data(added.utf8))
        #expect(afterAdd.submissionMode == .uploadOnly)
        #expect(afterAdd.requiredFiles == ["main.cpp", "util.h"])

        let removed = try #require(
            updateManifestRemovingScript(manifestJSON: added, filename: "secrettest_extra.sh"))
        let afterRemove = try JSONDecoder().decode(TestProperties.self, from: Data(removed.utf8))
        #expect(afterRemove.submissionMode == .uploadOnly)
        #expect(afterRemove.requiredFiles == ["main.cpp", "util.h"])
    }

    // MARK: - The two-way authoring refusal (DB helpers)

    @Test func settingUploadModeOnABrowserSetupIsRefused() async throws {
        try await withWebRoutesApp { app in
            let setup = try await wrInsertSetup(
                id: "sm_refuse1", manifest: Self.browserManifest, on: app)
            await #expect(throws: (any Error).self) {
                _ = try await setManifestSubmissionMode(
                    setup: setup, to: "uploadOnly", on: app.db)
            }
            // Refused means untouched.
            #expect(currentManifestSubmissionMode(setup.manifest) == "notebook")
        }
    }

    @Test func settingBrowserGradingOnAnUploadSetupIsRefused() async throws {
        try await withWebRoutesApp { app in
            let setup = try await wrInsertSetup(
                id: "sm_refuse2", manifest: Self.uploadManifest, on: app)
            await #expect(throws: (any Error).self) {
                _ = try await setManifestGradingMode(setup: setup, to: "browser", on: app.db)
            }
            #expect(currentManifestGradingMode(setup.manifest) == "worker")
        }
    }

    @Test func settingUploadModeOnAWorkerSetupPersists() async throws {
        try await withWebRoutesApp { app in
            let setup = try await wrInsertSetup(id: "sm_set1", on: app)
            let effective = try await setManifestSubmissionMode(
                setup: setup, to: "uploadOnly", on: app.db)
            #expect(effective == "uploadOnly")
            let reloaded = try #require(try await APITestSetup.find("sm_set1", on: app.db))
            let manifest = try #require(reloaded.decodedManifest())
            #expect(manifest.submissionMode == .uploadOnly)
            // The dict-level mutation must not have dropped anything.
            #expect(manifest.testSuites.count == 1)
        }
    }

    // MARK: - Student surface

    /// The vanity URL lands on the notebook page; for an upload assignment
    /// that page must hand students to the upload form instead of scaffolding
    /// an empty editor.  (The staff branch keeps the page for the workbench —
    /// asserted by code path, not here, because rendering the editor in tests
    /// writes working-copy files into the real Public/ tree.)
    @Test func notebookPageRedirectsStudentsToUploadForm() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "sm_nb1", manifest: Self.uploadManifest, on: app)
            try await wrInsertAssignment(
                testSetupID: "sm_nb1", title: "C++ Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/testsetups/sm_nb1/notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers["Location"].first ?? ""
                    #expect(
                        location.hasSuffix("/testsetups/sm_nb1/submit"),
                        "expected the upload form, got: \(location)")
                })
        }
    }

    @Test func submitPageShowsRequiredFilesAndDerivedAccept() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "sm_form1", manifest: Self.uploadManifest, on: app)
            try await wrInsertAssignment(
                testSetupID: "sm_form1", title: "C++ Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/testsetups/sm_form1/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("main.cpp, util.h"))
                    #expect(html.contains(#"accept=".cpp,.h,.ipynb,.lua,.m,.py,.r,.zip""#))
                })
        }
    }

    // MARK: - Edit page + edit/save

    @Test func editPageRendersTheCurrentSubmissionMode() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "sm_edit1", manifest: Self.uploadManifest, on: app)
            let a = try await wrInsertAssignment(
                testSetupID: "sm_edit1", title: "C++ Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("submissionModeSelect"))
                    #expect(
                        html.contains(#"value="uploadOnly" selected"#),
                        "the select should show the stored mode")
                })
        }
    }

    @Test func editSavePersistsAnUploadModeChange() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor", cookie: cookie, on: app)

            let setup = try await wrInsertSetup(id: "sm_save1", on: app)
            // A syntactically-valid empty zip so the save flow's support-file
            // extraction has something to open.
            try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
                .write(to: URL(fileURLWithPath: setup.zipPath))
            let a = try await wrInsertAssignment(
                testSetupID: "sm_save1", title: "C++ Lab", isOpen: false, on: app)
            // A draft solution so the save reaches the submission-mode write
            // (the handler requires a solution before persisting anything).
            let draftPath =
                try ensureDraftNotebookDirectory(
                    testSetupsDirectory: app.testSetupsDirectory, setupID: "sm_save1")
                + "solution.ipynb"
            try Data(Self.sampleNotebookJSON.utf8).write(to: URL(fileURLWithPath: draftPath))

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        [
                            "_csrf": csrf, "assignmentName": "C++ Lab", "dueAt": "",
                            "submissionMode": "uploadOnly",
                        ],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let reloaded = try #require(try await APITestSetup.find("sm_save1", on: app.db))
            let manifest = try #require(reloaded.decodedManifest())
            #expect(manifest.submissionMode == .uploadOnly)
        }
    }

    @Test func editSaveRefusesUploadModeOnABrowserAssignment() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor", cookie: cookie, on: app)

            let setup = try await wrInsertSetup(
                id: "sm_save2", manifest: Self.browserManifest, on: app)
            try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
                .write(to: URL(fileURLWithPath: setup.zipPath))
            let a = try await wrInsertAssignment(
                testSetupID: "sm_save2", title: "Browser Lab", isOpen: false, on: app)
            let draftPath =
                try ensureDraftNotebookDirectory(
                    testSetupsDirectory: app.testSetupsDirectory, setupID: "sm_save2")
                + "solution.ipynb"
            try Data(Self.sampleNotebookJSON.utf8).write(to: URL(fileURLWithPath: draftPath))

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/edit/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        [
                            "_csrf": csrf, "assignmentName": "Browser Lab", "dueAt": "",
                            "submissionMode": "uploadOnly",
                        ],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers["Location"].first ?? ""
                    #expect(
                        location.contains("error="),
                        "expected the refusal banner, got: \(location)")
                })

            // Refused means the stored manifest is untouched.
            let reloaded = try #require(try await APITestSetup.find("sm_save2", on: app.db))
            let manifest = try #require(reloaded.decodedManifest())
            #expect(manifest.submissionMode == .notebook)
            #expect(manifest.gradingMode == .browser)
        }
    }
}
