// Tests/APITests/NewAssignmentUploadOnlyTests.swift
//
// An upload-only language declared on the create page survives the draft's
// suite rebuilds and the publish (#1720). Declaring C++, Racket or Java sets
// `uploadOnly` + `worker`; the rebuilds used to call the fresh manifest
// builder, which wrote `notebook` and the section's grading mode over it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct NewAssignmentUploadOnlyTests {
    static let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

    /// A draft in `courseID`, made the way the create page makes one, with
    /// `language` declared on it.
    private func makeDraft(
        id: String, language: AssignmentLanguage, courseID: UUID, on app: Application
    ) async throws -> APITestSetup {
        let zipPath = app.testSetupsDirectory + "\(id).zip"
        _ = try await createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let setup = APITestSetup(
            id: id,
            manifest: try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "browser"),
            zipPath: zipPath,
            courseID: courseID)
        try await setup.save(on: app.db)
        try await declareManifestLanguage(setup: setup, to: language, on: app.db)
        return setup
    }

    /// Publishes the draft `draftID` into `sectionID` from the create page.
    private func publish(
        draftID: String, title: String, sectionID: UUID, on app: Application
    ) async throws -> TestProperties {
        let cookie = try await arLoginAsInstructor(on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-Upload-Only-Draft"
        let notebook = Data(Self.notebook.utf8)
        try await app.asyncTest(
            .POST, "/instructor/new/save",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = .init(
                    buffer: arMultipartBody(
                        boundary: boundary,
                        fields: [
                            ("_csrf", csrf), ("draftID", draftID), ("assignmentName", title),
                            ("sectionID", sectionID.uuidString),
                        ],
                        files: [
                            ("assignmentNotebookFile", "assignment.ipynb", "application/json", notebook),
                            ("solutionNotebookFile", "solution.ipynb", "application/json", notebook),
                        ]))
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/instructor")
            })
        let assignment = try #require(
            try await APIAssignment.query(on: app.db).filter(\.$title == title).first())
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        return try #require(setup.decodedManifest())
    }

    /// A section that grades in the browser by default, so the section's mode
    /// differs from the `worker` an upload-only language requires.
    private func browserSection(courseID: UUID, on app: Application) async throws -> UUID {
        let section = APICourseSection(
            name: "Labs", defaultGradingMode: "browser", sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        return try section.requireID()
    }

    @Test func publishingACppDraftKeepsUploadOnlyAndWorker() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let sectionID = try await browserSection(courseID: courseID, on: app)
            _ = try await makeDraft(id: "setup_cpp_draft", language: .cpp, courseID: courseID, on: app)

            let props = try await publish(
                draftID: "setup_cpp_draft", title: "C++ Lab", sectionID: sectionID, on: app)
            #expect(props.language == .cpp)
            #expect(props.languageDeclared == true)
            #expect(props.submissionMode == .uploadOnly)
            #expect(props.gradingMode == .worker)
        }
    }

    /// The other half of the rule: a language with an editor kernel keeps the
    /// notebook mode and takes the section's grading mode, as before.
    @Test func publishingAPythonDraftTakesTheSectionsGradingMode() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let sectionID = try await browserSection(courseID: courseID, on: app)
            _ = try await makeDraft(id: "setup_py_draft", language: .python, courseID: courseID, on: app)

            let props = try await publish(
                draftID: "setup_py_draft", title: "Python Lab", sectionID: sectionID, on: app)
            #expect(props.language == .python)
            #expect(props.submissionMode == .notebook)
            #expect(props.gradingMode == .browser)
        }
    }

    /// The pure rebuild, for each upload-only language and one with a
    /// kernel. The draft service's two suite actions call it too.
    @Test(arguments: AssignmentLanguage.allCases)
    func theDraftRebuildFollowsTheDeclaredLanguage(language: AssignmentLanguage) throws {
        var draft = try #require(
            decodeManifest(
                fromJSON: try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "browser")))
        draft.language = language
        draft.languageDeclared = true
        if requiresUploadOnlySubmission(language) {
            draft.submissionMode = .uploadOnly
            draft.gradingMode = .worker
        }

        let rebuilt = try #require(
            decodeManifest(
                fromJSON: try rebuildDraftManifestJSON(
                    draft, testSuites: [], includeMakefile: true, sectionGradingMode: "browser",
                    starterNotebook: "lab.ipynb")))
        #expect(rebuilt.language == language)
        #expect(rebuilt.languageDeclared == true)
        #expect(rebuilt.makefile != nil)
        #expect(rebuilt.starterNotebook == "lab.ipynb")
        if requiresUploadOnlySubmission(language) {
            #expect(rebuilt.submissionMode == .uploadOnly)
            #expect(rebuilt.gradingMode == .worker)
        } else {
            #expect(rebuilt.submissionMode == .notebook)
            #expect(rebuilt.gradingMode == .browser)
        }
    }
}
