// Tests/APITests/SubmissionDiffRoutesTests.swift
//
// GET /instructor/:assignmentID/submissions/:submissionID/diff — what a
// student changed against the starter: notebooks cell by cell with the
// instructor's test cells dropped from both sides, single files against the
// starter file of the same name, and a plain message where no comparison is
// possible. Plus the two links that reach it.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized)
struct SubmissionDiffRoutesTests {

    private func notebook(cells: [(type: String, source: String)]) -> Data {
        let rendered = cells.map { cell in
            #"{"cell_type":\#(cell.type.debugDescription),"metadata":{},"source":\#(cell.source.debugDescription)"#
                + (cell.type == "code" ? #","execution_count":null,"outputs":[]}"# : "}")
        }.joined(separator: ",")
        return Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\#(rendered)]}"#.utf8)
    }

    @Test func notebookDiffShowsStudentChangesAndDropsTestCells() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "diff_alice", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let setup = try await arInsertSetup(id: "diff_setup", on: app)
            _ = try await arAttachStarterNotebook(
                to: setup,
                bytes: notebook(cells: [
                    (type: "markdown", source: "# Warm-up"),
                    (type: "code", source: "def f():\n    return 1\n"),
                    (type: "code", source: "# TEST: tier=secret\nassert f() == 1"),
                ]),
                on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "diff_setup", title: "Diff Lab", isOpen: true, on: app)
            let submission = try await arInsertSubmission(
                id: "sub_diff_nb", testSetupID: "diff_setup",
                userID: student.requireID(), on: app)
            submission.filename = "warmup.ipynb"
            try await submission.save(on: app.db)
            try notebook(cells: [
                (type: "markdown", source: "# Warm-up"),
                (type: "code", source: "def f():\n    return 2\n"),
                (type: "code", source: "print(f())"),
                (type: "code", source: "# TEST: tier=secret\nassert f() == 1"),
            ]).write(to: URL(fileURLWithPath: submission.zipPath))

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions/sub_diff_nb/diff",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("diff_alice"))
                    #expect(body.contains(#"class="diff-removed""#))
                    #expect(body.contains("return 1"))
                    #expect(body.contains(#"class="diff-added""#))
                    #expect(body.contains("return 2"))
                    #expect(body.contains("print(f())"))
                    #expect(body.contains("+3 added"), "the changed line and the two-line new cell")
                    #expect(body.contains("−1 removed"))
                    #expect(!body.contains("assert f()"), "instructor test cells are not the student's work")
                    #expect(body.contains("diff-marker"))
                })
        }
    }

    @Test func singleFileDiffsAgainstTheStarterOfTheSameName() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "diff_bob", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            let setup = try await arInsertSetup(id: "diff_file_setup", on: app)
            try await arMakeZip(
                at: setup.zipPath,
                entries: [("warmup.py", "def f():\n    return 1\n"), ("test.sh", "exit 0\n")])
            let assignment = try await arInsertAssignment(
                testSetupID: "diff_file_setup", title: "Diff Lab", isOpen: true, on: app)
            let submission = try await arInsertSubmission(
                id: "sub_diff_py", testSetupID: "diff_file_setup",
                userID: student.requireID(), on: app)
            // The artifact is stored under its own extension for a raw upload.
            submission.zipPath = app.submissionsDirectory + "sub_diff_py.py"
            submission.filename = "warmup.py"
            try await submission.save(on: app.db)
            try "def f():\n    return 42\n".write(
                to: URL(fileURLWithPath: submission.zipPath), atomically: true, encoding: .utf8)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions/sub_diff_py/diff",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("starter warmup.py"))
                    #expect(body.contains("return 1"))
                    #expect(body.contains("return 42"))
                    #expect(body.contains("+1 added"))
                    #expect(body.contains("−1 removed"))
                })
        }
    }

    @Test func zipWithoutANotebookExplainsInsteadOfDiffing() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "diff_carol", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "diff_zip_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "diff_zip_setup", title: "Diff Lab", isOpen: true, on: app)
            let submission = try await arInsertSubmission(
                id: "sub_diff_zip", testSetupID: "diff_zip_setup",
                userID: student.requireID(), on: app)
            try await arMakeZip(at: submission.zipPath, entries: [("main.cpp", "int main() {}\n")])

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/submissions/sub_diff_zip/diff",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("cannot be compared"))
                    #expect(!res.body.string.contains("diff-table"))
                })
        }
    }

    @Test func submissionFromAnotherAssignmentIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "diff_dave", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "diff_a", on: app)
            try await arInsertSetup(id: "diff_b", on: app)
            let assignmentA = try await arInsertAssignment(
                testSetupID: "diff_a", title: "A", isOpen: true, on: app)
            _ = try await arInsertAssignment(testSetupID: "diff_b", title: "B", isOpen: true, on: app)
            _ = try await arInsertSubmission(
                id: "sub_diff_b", testSetupID: "diff_b", userID: student.requireID(), on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignmentA.publicID)/submissions/sub_diff_b/diff",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test func linksReachTheDiffFromHistoryAndFromTheStaffResultsView() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "diff_erin", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            try await arInsertSetup(id: "diff_links", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "diff_links", title: "Diff Lab", isOpen: true, on: app)
            let studentID = try student.requireID()
            _ = try await arInsertSubmission(
                id: "sub_diff_link", testSetupID: "diff_links", userID: studentID, on: app)
            let diffPath = "/instructor/\(assignment.publicID)/submissions/sub_diff_link/diff"

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/students/\(studentID.uuidString)/history",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains(diffPath))
                })
            try await app.asyncTest(
                .GET, "/submissions/sub_diff_link",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains(diffPath), "staff see the diff link")
                })
            let studentCookie = try await loginUser(
                username: "diff_erin", password: "testpassword", role: "user", on: app)
            try await app.asyncTest(
                .GET, "/submissions/sub_diff_link",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains(diffPath), "students are not offered it")
                })
        }
    }
}
