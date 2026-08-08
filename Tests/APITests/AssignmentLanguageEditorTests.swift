// Tests/APITests/AssignmentLanguageEditorTests.swift
//
// The Language select on the assignment edit page:
//
//   * option construction (discovered from `AssignmentLanguage.allCases`, with
//     the derive-it entry that keeps a declaration from being a one-way door),
//   * the edit page rendering the stored declaration,
//   * the edit-save path declaring a language, clearing it, and leaving it
//     alone when the field is absent (a stale tab),
//   * and the three refusals surfacing their own distinct reasons rather than
//     one generic message.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AssignmentLanguageEditorTests {

    static let plainManifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let rDeclaredManifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"r","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    static let generatedManifest = """
        {"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_bmi_01.py","generatedBy":"bmi"}],"timeLimitSeconds":10}
        """
    static let sampleNotebookJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[],"execution_count":null}]}
        """

    // MARK: - Option construction (pure)

    @Test func nothingRecordedSelectsTheNoLanguageEntry() {
        let options = AssignmentLanguageOption.options(recorded: nil)
        let selected = options.filter(\.selected)
        #expect(selected.count == 1)
        #expect(selected.first?.value == noLanguageChoice)
    }

    @Test func aRecordedLanguageIsTheSelectedOption() {
        let selected = AssignmentLanguageOption.options(recorded: "r").filter(\.selected)
        #expect(selected.count == 1)
        #expect(selected.first?.value == "r")
    }

    /// Defensive: a manifest carrying a language this build does not know must
    /// still render a coherent select rather than one with nothing selected.
    @Test func anUnknownRecordedLanguageFallsBackToTheNoLanguageEntry() {
        let selected = AssignmentLanguageOption.options(recorded: "fortran").filter(\.selected)
        #expect(selected.count == 1)
        #expect(selected.first?.value == noLanguageChoice)
    }

    /// Discovered, not enumerated: a sixth language appears in the select with
    /// no template edit, which is the rule the kernel-alias generator and the
    /// runner capability probe already follow.
    @Test func everyLanguageIsOffered() {
        let values = Set(AssignmentLanguageOption.options(recorded: nil).map(\.value))
        for language in AssignmentLanguage.allCases {
            #expect(
                values.contains(language.rawValue),
                "\(language) is missing from the Language select")
        }
        #expect(
            values.contains(noLanguageChoice),
            "the no-language declaration must always be offered")
    }

    @Test func optionLabelsAreTheLanguagesDisplayNames() {
        let options = AssignmentLanguageOption.options(recorded: nil)
        let byValue = Dictionary(uniqueKeysWithValues: options.map { ($0.value, $0.label) })
        for language in AssignmentLanguage.allCases {
            #expect(byValue[language.rawValue] == language.displayName)
        }
    }

    // MARK: - Render

    @Test func editPageRendersTheStoredLanguage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "lang_edit1", manifest: Self.rDeclaredManifest, on: app)
            let a = try await wrInsertAssignment(
                testSetupID: "lang_edit1", title: "R Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(a.publicID)/edit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("assignmentLanguageSelect"))
                    #expect(
                        html.contains(#"value="r" selected"#),
                        "the select should show the declared language")
                })
        }
    }

    // MARK: - Save

    /// Sets up an assignment the save handler will actually reach the language
    /// write on: it requires a solution draft and an openable zip first.
    private func saveableAssignment(
        id: String, manifest: String, title: String, on app: Application
    ) async throws -> APIAssignment {
        let setup = try await wrInsertSetup(id: id, manifest: manifest, on: app)
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
            .write(to: URL(fileURLWithPath: setup.zipPath))
        let assignment = try await wrInsertAssignment(
            testSetupID: id, title: title, isOpen: false, on: app)
        let draftPath =
            try ensureDraftNotebookDirectory(
                testSetupsDirectory: app.testSetupsDirectory, setupID: id) + "solution.ipynb"
        try Data(Self.sampleNotebookJSON.utf8).write(to: URL(fileURLWithPath: draftPath))
        return assignment
    }

    private func postEdit(
        assignment: APIAssignment, fields: [String: String], cookie: String, on app: Application
    ) async throws -> HTTPStatus {
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor", cookie: cookie, on: app)
        var status = HTTPStatus.internalServerError
        var body = fields
        body["_csrf"] = csrf
        try await app.asyncTest(
            .POST, "/instructor/\(assignment.publicID)/edit/save",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func editSaveDeclaresALanguage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save1", manifest: Self.plainManifest, title: "Lab", on: app)

            let status = try await postEdit(
                assignment: a,
                fields: ["assignmentName": "Lab", "dueAt": "", "assignmentLanguage": "lua"],
                cookie: cookie, on: app)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APITestSetup.find("lang_save1", on: app.db))
            #expect(currentManifestLanguage(reloaded.manifest) == "lua")
        }
    }

    /// The escape hatch. `resolve` treats a recorded language as authoritative
    /// over the notebook and the suite, so without this the first choice would
    /// be permanent.
    @Test func editSaveDeclaresNoLanguage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save2", manifest: Self.rDeclaredManifest, title: "Lab", on: app)

            let status = try await postEdit(
                assignment: a,
                fields: [
                    "assignmentName": "Lab", "dueAt": "", "assignmentLanguage": noLanguageChoice,
                ],
                cookie: cookie, on: app)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APITestSetup.find("lang_save2", on: app.db))
            #expect(currentManifestLanguage(reloaded.manifest) == nil)
            // The flag is the point: "no language" is now an ANSWER, so this is
            // distinguishable from an assignment nobody has declared.
            #expect(reloaded.decodedManifest()?.languageDeclared == true)
        }
    }

    /// A form posted from a tab opened before the field existed carries no
    /// `assignmentLanguage` at all. That is silence, not "detect
    /// automatically", and must leave the declaration untouched.
    @Test func anAbsentFieldLeavesTheDeclarationAlone() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save3", manifest: Self.rDeclaredManifest, title: "Lab", on: app)

            let status = try await postEdit(
                assignment: a, fields: ["assignmentName": "Lab", "dueAt": ""],
                cookie: cookie, on: app)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APITestSetup.find("lang_save3", on: app.db))
            #expect(currentManifestLanguage(reloaded.manifest) == "r")
        }
    }

    // MARK: - The upload-only implication

    /// Declaring C++ SETS upload-only rather than refusing without it. The
    /// language implies the mode — C++ has no notebook workflow — and making the
    /// declaration carry it is what lets an author answer one question instead
    /// of performing the old three-step dance (grading mode, then submission
    /// mode, then language, each refusal naming the next step).
    @Test func declaringCppAlsoSetsUploadOnly() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save4", manifest: Self.plainManifest, title: "Lab", on: app)

            let status = try await postEdit(
                assignment: a,
                fields: ["assignmentName": "Lab", "dueAt": "", "assignmentLanguage": "cpp"],
                cookie: cookie, on: app)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APITestSetup.find("lang_save4", on: app.db))
            #expect(currentManifestLanguage(reloaded.manifest) == "cpp")
            #expect(reloaded.decodedManifest()?.submissionMode == .uploadOnly)
        }
    }

    /// Setting the mode and the language in ONE save has to work, which is why
    /// the handler applies submissionMode first — the C++ guard reads the mode
    /// the same request just set.
    @Test func editSaveAcceptsCppTogetherWithUploadOnlyInOneRequest() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save5", manifest: Self.plainManifest, title: "Lab", on: app)

            let status = try await postEdit(
                assignment: a,
                fields: [
                    "assignmentName": "Lab", "dueAt": "",
                    "submissionMode": "uploadOnly", "assignmentLanguage": "cpp",
                ],
                cookie: cookie, on: app)
            #expect(status == .seeOther)

            let reloaded = try #require(try await APITestSetup.find("lang_save5", on: app.db))
            #expect(currentManifestLanguage(reloaded.manifest) == "cpp")
            #expect(reloaded.decodedManifest()?.submissionMode == .uploadOnly)
        }
    }

    @Test func editSaveRefusesAChangeOnceGeneratedTestsExist() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save6", manifest: Self.generatedManifest, title: "Lab", on: app)

            _ = try await postEdit(
                assignment: a,
                fields: ["assignmentName": "Lab", "dueAt": "", "assignmentLanguage": "r"],
                cookie: cookie, on: app)

            let reloaded = try #require(try await APITestSetup.find("lang_save6", on: app.db))
            #expect(
                currentManifestLanguage(reloaded.manifest) == nil,
                "generated filenames carry the language's extension, so the change is refused")
        }
    }

    /// Clearing is guarded exactly like setting: it changes how generated tests
    /// would render just as much.
    @Test func clearingIsAlsoRefusedOnceGeneratedTestsExist() async throws {
        try await withWebRoutesApp { app in
            let generatedAndDeclared = """
                {"schemaVersion":1,"gradingMode":"worker","language":"python","requiredFiles":[],\
                "testSuites":[{"tier":"public","script":"publictest_bmi_01.py","generatedBy":"bmi"}],\
                "timeLimitSeconds":10}
                """
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let a = try await saveableAssignment(
                id: "lang_save7", manifest: generatedAndDeclared, title: "Lab", on: app)

            _ = try await postEdit(
                assignment: a,
                fields: ["assignmentName": "Lab", "dueAt": "", "assignmentLanguage": ""],
                cookie: cookie, on: app)

            let reloaded = try #require(try await APITestSetup.find("lang_save7", on: app.db))
            #expect(currentManifestLanguage(reloaded.manifest) == "python")
        }
    }
}
