// Tests/APITests/StaffPracticeWriteBackTests.swift
//
// Staff test-submit from the student view, as a student does. After a browser
// result, the submitted notebook is written back to the viewer's student-view
// copy: a student's own copy, or the staff practice copy. It never reaches the
// staff authoring copy, which "Save to assignment" writes back for every
// student.

import Core
import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class StaffPracticeWriteBackTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-practice")
    }

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],\
        "testSuites":[{"tier":"public","script":"test_public.py"}],"timeLimitSeconds":10,"makefile":null}
        """

    private func collection(setupID: String) -> String {
        """
        {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,"buildStatus":"passed",\
        "compilerOutput":null,"outcomes":[{"testName":"test_public","testClass":null,"tier":"public",\
        "status":"pass","shortResult":"passed","longResult":null,"executionTimeMs":5,\
        "memoryUsageBytes":null,"attemptNumber":1,"isFirstPassSuccess":true}],"totalTests":1,\
        "passCount":1,"failCount":0,"errorCount":0,"timeoutCount":0,"executionTimeMs":5,\
        "runnerVersion":"browser-wasm-runner/1.0","timestamp":"2026-01-01T00:00:00Z"}
        """
    }

    private func multipart(boundary: String, fields: [(String, String)], notebook: Data) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: 4096)
        for (name, value) in fields {
            buf.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        buf.writeString(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"notebook\"; filename=\"notebook.ipynb\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n")
        buf.writeBytes(notebook)
        buf.writeString("\r\n--\(boundary)--\r\n")
        return buf
    }

    private func path(_ relative: String) -> String {
        app.directory.publicDirectory + "jupyterlite/files/" + relative
    }

    @Test func aStaffBrowserResultWritesThePracticeCopyNotTheAuthoringCopy() async throws {
        try await withApp(app) { _ in
            let course = APICourse(code: "PR101", name: "Practice Course", enrollmentMode: .auto)
            try await course.save(on: app.db)
            let setupID = "setup_practice_writeback"
            try await makeTestSetup(
                on: app, id: setupID, courseID: try course.requireID(), manifest: manifest, withNotebook: false)
            let assignment = APIAssignment(
                testSetupID: setupID, title: "Practice Lab", isOpen: true, courseID: try course.requireID())
            try await assignment.save(on: app.db)

            let cookie = try await loginUser(username: "practice_ta", password: "pass", role: "instructor", on: app)
            try await promoteToInstructor("practice_ta", on: app)
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "practice_ta").first())
            let userID = try staff.requireID()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            let submitted = Data(
                #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["answer = 42"],"metadata":{},"outputs":[]}]}"#
                    .utf8)
            try await app.asyncTest(
                .POST, "/api/v1/submissions/browser-result",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.body = .init(
                        buffer: self.multipart(
                            boundary: "practice-boundary",
                            fields: [
                                ("_csrf", csrf), ("collection", self.collection(setupID: setupID)),
                                ("testSetupID", setupID),
                            ],
                            notebook: submitted))
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": "practice-boundary"])
                },
                afterResponse: { res in #expect(res.status == .ok, "body: \(res.body.string)") })

            let practice = try String(
                contentsOfFile: path(
                    staffPracticeWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: .assignment)),
                encoding: .utf8)
            #expect(practice.contains("answer = 42"))
            let authoring = path(userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID))
            let authoringText = (try? String(contentsOfFile: authoring, encoding: .utf8)) ?? ""
            #expect(authoringText.contains("answer = 42") == false)
        }
    }
}
