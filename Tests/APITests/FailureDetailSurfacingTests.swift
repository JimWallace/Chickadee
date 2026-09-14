// Tests/APITests/FailureDetailSurfacingTests.swift
//
// The entry-to-outcome join for `FailureDetail` and its effect on the student
// results page: a student reads the masked text, staff read everything, the
// hint survives every level, and a pass is never masked.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct FailureDetailSurfacingTests {

    @Test func buildFailureDetailByFilename_keysFilenameAndStemAndSkipsFull() {
        let props = TestProperties(testSuites: [
            TestSuiteEntry(tier: .pub, script: "publictest_a.py", failureDetail: .actualOnly),
            TestSuiteEntry(tier: .pub, script: "publictest_b.py", failureDetail: .full),
            TestSuiteEntry(tier: .pub, script: "publictest_c.py"),
        ])
        let map = buildFailureDetailByFilename(props)
        #expect(map["publictest_a.py"] == .actualOnly)
        #expect(map["publictest_a"] == .actualOnly)
        #expect(map["publictest_b.py"] == nil, "full is the absence of a setting")
        #expect(map["publictest_c.py"] == nil)
    }

    private let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[\
        {"tier":"public","script":"publictest_a.py","failureDetail":"actualOnly","hint":"HINT_A"},\
        {"tier":"public","script":"publictest_b.py","failureDetail":"verdictOnly","hint":"HINT_B"},\
        {"tier":"public","script":"publictest_c.py","failureDetail":"verdictOnly"}\
        ],"timeLimitSeconds":10}
        """

    private let failureA = """
        stdout:
        wrong value
          input:    classify(3)
          expected: 'ANSWER_A'
          got:      'GOT_A'
        """

    @Test func studentsReadTheMaskedTextAndStaffReadEverything() async throws {
        try await withWebRoutesApp { app in
            let studentCookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "setup_fd", manifest: manifest, on: app)
            _ = try await wrInsertAssignment(
                testSetupID: "setup_fd", title: "Detail Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_fd", testSetupID: "setup_fd", userID: student.requireID(), on: app)
            try await wrInsertResult(
                submissionID: "sub_fd",
                outcomes: [
                    wrMakeOutcome(
                        name: "publictest_a", status: .fail,
                        shortResult: "publictest_a: wrong value", longResult: failureA),
                    wrMakeOutcome(
                        name: "publictest_b", status: .fail,
                        shortResult: "expected ANSWER_B, got GOT_B",
                        longResult: "stderr:\nexpected ANSWER_B, got GOT_B"),
                    wrMakeOutcome(
                        name: "publictest_c", status: .pass,
                        shortResult: "passed", longResult: "all good ANSWER_C"),
                ],
                on: app)

            try await app.asyncTest(
                .GET, "/submissions/sub_fd",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    // actualOnly: the student's own side survives, the answer does not.
                    #expect(body.contains("GOT_A"))
                    #expect(!body.contains("ANSWER_A"))
                    #expect(body.contains("HINT_A"), "the hint is for the student")
                    // verdictOnly: nothing of the message, verdict + hint only.
                    #expect(!body.contains("ANSWER_B"))
                    #expect(!body.contains("GOT_B"))
                    #expect(body.contains("did not pass"))
                    #expect(body.contains("HINT_B"))
                    // A pass is never masked.
                    #expect(body.contains("ANSWER_C"))
                })

            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await app.asyncTest(
                .GET, "/submissions/sub_fd",
                beforeRequest: { req in req.headers.add(name: .cookie, value: instructorCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("ANSWER_A"), "staff always read the full text")
                    #expect(body.contains("ANSWER_B"))
                })
        }
    }
}
