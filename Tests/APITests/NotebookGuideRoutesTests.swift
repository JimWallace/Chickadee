// Tests/APITests/NotebookGuideRoutesTests.swift
//
// GET /testsetups/:id/notebook-guide.json end to end: an enrolled student gets
// their own guide with public results only, a student with no submission gets
// the fresh guide, and someone outside the course gets nothing.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) struct NotebookGuideRoutesTests {

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","requiredFiles":[],\
        "sections":[{"id":"s1","name":"Task 1: Warm up"}],\
        "testSuites":[{"tier":"public","script":"test_a.py","sectionID":"s1"},\
        {"tier":"secret","script":"secret_b.py","sectionID":"s1"}],"timeLimitSeconds":10}
        """

    private func get(_ path: String, cookie: String?, on app: Application) async throws -> (HTTPStatus, String) {
        var status = HTTPStatus.imATeapot
        var body = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in if let cookie { req.headers.add(name: .cookie, value: cookie) } },
            afterResponse: { res in
                status = res.status
                body = res.body.string
            })
        return (status, body)
    }

    @Test func anEnrolledStudentGetsPublicResultsOnly() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "setup_guide", manifest: manifest, on: app)
            try await wrInsertAssignment(testSetupID: "setup_guide", title: "Guide Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_guide", testSetupID: "setup_guide", userID: student.requireID(), attemptNumber: 2, on: app)
            try await wrInsertResult(
                submissionID: "sub_guide",
                outcomes: [
                    wrMakeOutcome(name: "test_a", status: .pass),
                    wrMakeOutcome(name: "secret_b", tier: .secret, status: .fail, shortResult: "HIDDEN-DETAIL"),
                ], on: app)

            let (status, body) = try await get("/testsetups/setup_guide/notebook-guide.json", cookie: cookie, on: app)
            #expect(status == .ok)
            let guide = try JSONDecoder().decode(NotebookGuide.self, from: Data(body.utf8))
            #expect(guide.attempt?.number == 2)
            #expect(guide.attempt?.pending == false)
            #expect(guide.tasks.count == 1)
            #expect(guide.tasks[0].label == "Task 1")
            #expect(guide.tasks[0].status == "pass")
            #expect(guide.tasks[0].checks.map(\.name) == ["test_a"])
            #expect(guide.tasks[0].hiddenCount == 1)
            #expect(!body.contains("HIDDEN-DETAIL"))
            #expect(!body.contains("secret_b"))
        }
    }

    @Test func aStudentWithNoSubmissionGetsTheFreshGuide() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            try await wrInsertSetup(id: "setup_fresh", manifest: manifest, on: app)
            try await wrInsertAssignment(testSetupID: "setup_fresh", title: "Fresh Lab", isOpen: true, on: app)

            let (status, body) = try await get("/testsetups/setup_fresh/notebook-guide.json", cookie: cookie, on: app)
            #expect(status == .ok)
            let guide = try JSONDecoder().decode(NotebookGuide.self, from: Data(body.utf8))
            #expect(guide.attempt == nil)
            #expect(guide.tasks.map(\.status) == ["fresh"])
        }
    }

    @Test func aStudentOutsideTheCourseGetsNothing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrInsertSetup(id: "setup_other", manifest: manifest, on: app)

            let (status, body) = try await get("/testsetups/setup_other/notebook-guide.json", cookie: cookie, on: app)
            #expect(status != .ok)
            #expect(!body.contains("Task 1"))
        }
    }

    @Test func aClosedLabTheStudentNeverOpenedIsRefused() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            try await wrInsertSetup(id: "setup_closed", manifest: manifest, on: app)
            try await wrInsertAssignment(testSetupID: "setup_closed", title: "Closed Lab", isOpen: false, on: app)

            let (status, body) = try await get("/testsetups/setup_closed/notebook-guide.json", cookie: cookie, on: app)
            #expect(status == .forbidden)
            #expect(!body.contains("Task 1"))
        }
    }

    @Test func anUnknownSetupIsNotFound() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let (status, _) = try await get("/testsetups/nope/notebook-guide.json", cookie: cookie, on: app)
            #expect(status == .notFound)
        }
    }
}
