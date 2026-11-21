// Tests/APITests/Grading/StudentDrilldownGradeTests.swift
//
// #1111 — the live inconsistency the best-grade audit found: the
// per-student drilldown page used to compute its grade from the
// *worker-preferred* result, so a submission with a 100 % browser result
// later regraded 80 % by the worker showed 100 % on the roster but 80 % on
// the page the instructor opened from that roster row.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class StudentDrilldownGradeTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-drilldown-grade")
    }

    /// A submission with a 100 % browser result AND a later 80 % worker
    /// result. Every surface — including the per-student drilldown — must
    /// show 100 %.
    @Test func perStudentHistoryShowsHighestGradeAcrossSources() async throws {
        try await withApp(app) { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_ddg", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_ddg", title: "Drilldown Grade", isOpen: true, on: app)
            let student = try await arInsertStudent(username: "ddg_student", on: app)
            let studentID = try student.requireID()
            // The drilldown guard requires a `.student` enrollment in the
            // assignment's course.
            try await arEnrollStudentInTestCourse(student, on: app)
            _ = try await arInsertSubmission(
                id: "sub_ddg", testSetupID: "setup_ddg", userID: studentID, on: app)

            try await APIResult(
                id: "res_ddg_browser", submissionID: "sub_ddg",
                source: "browser"
            ).saveWithCollection(json: #"{"passCount": 5, "totalTests": 5}"#, on: app.db)
            try await APIResult(
                id: "res_ddg_worker", submissionID: "sub_ddg",
                source: "worker"
            ).saveWithCollection(json: #"{"passCount": 4, "totalTests": 5}"#, on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/students/\(studentID.uuidString)/history",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "history page should render, got \(res.status)")
                    let html = res.body.string
                    #expect(
                        html.contains("100%"),
                        "drilldown must show the highest grade across all sources (100%), not the worker-preferred 80%"
                    )
                    #expect(
                        !html.contains("<strong>80%</strong>"),
                        "the worker-preferred 80% must not be shown as the grade")
                    // It does appear as the native side of the staff
                    // disagreement badge (docs/grading-integrity.md, D8).
                    #expect(html.contains("Browser 100% · native 80%"))
                })
        }
    }
}
