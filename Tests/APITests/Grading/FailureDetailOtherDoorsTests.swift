// Tests/APITests/Grading/FailureDetailOtherDoorsTests.swift
//
// `FailureDetail` outside the results page (#2662): the JSON results API and
// the personal data export apply the same mask a student reads on the page,
// staff still read the full text, and a relaxed setting re-serves a past
// result (it is part of the API's ETag).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct FailureDetailOtherDoorsTests {

    private let failureA = """
        stdout:
        wrong value
          input:    classify(3)
          expected: 'ANSWER_A'
          got:      'GOT_A'
        """

    private var outcomes: [TestOutcome] {
        [
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
            wrMakeOutcome(
                name: "publictest_d", status: .fail,
                shortResult: "Skipped: prerequisite 'publictest_b.py' did not pass"),
        ]
    }

    private let detailMap: [String: FailureDetail] = [
        "publictest_a": .actualOnly,
        "publictest_b": .verdictOnly,
        "publictest_c": .verdictOnly,
        "publictest_d": .verdictOnly,
    ]

    private func manifest(bDetail: FailureDetail) -> String {
        """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[\
        {"tier":"public","script":"publictest_a.py","failureDetail":"actualOnly"},\
        {"tier":"public","script":"publictest_b.py","failureDetail":"\(bDetail.rawValue)"}\
        ],"timeLimitSeconds":10}
        """
    }

    private func text(of outcomes: [TestOutcome]) -> String {
        outcomes.map { "\($0.shortResult)\n\($0.longResult ?? "")" }.joined(separator: "\n")
    }

    // MARK: - maskingFailureDetail (pure)

    @Test func masksFailuresAndLeavesPassesAndSkipsAlone() throws {
        let masked = maskingFailureDetail(of: outcomes, failureDetailByFilename: detailMap)
        let byName = Dictionary(uniqueKeysWithValues: masked.map { ($0.testName, $0) })

        let a = try #require(byName["publictest_a"])
        #expect((a.longResult ?? "").contains("GOT_A"))
        #expect(!text(of: [a]).contains("ANSWER_A"))

        let b = try #require(byName["publictest_b"])
        #expect(b.shortResult == "did not pass")
        #expect(b.longResult == nil)

        let c = try #require(byName["publictest_c"])
        #expect(c.longResult == "all good ANSWER_C", "a pass is never masked")

        let d = try #require(byName["publictest_d"])
        #expect(d.shortResult.hasPrefix("Skipped: prerequisite"), "a dependency skip is never masked")
    }

    @Test func keepsEveryFieldButTheTwoTexts() throws {
        let masked = maskingFailureDetail(of: outcomes, failureDetailByFilename: detailMap)
        #expect(masked.map(\.testName) == outcomes.map(\.testName))
        #expect(masked.map(\.status) == outcomes.map(\.status))
        #expect(masked.map(\.score) == outcomes.map(\.score))
        #expect(masked.map(\.points) == outcomes.map(\.points))
        #expect(masked.map(\.tier) == outcomes.map(\.tier))
    }

    @Test func anEmptyMapChangesNothing() {
        let masked = maskingFailureDetail(of: outcomes, failureDetailByFilename: [:])
        #expect(masked == outcomes)
    }

    @Test func fingerprintChangesWithTheSetting() {
        #expect(failureDetailFingerprint([:]).isEmpty)
        #expect(
            failureDetailFingerprint(["a": .actualOnly, "b": .verdictOnly])
                == failureDetailFingerprint(["b": .verdictOnly, "a": .actualOnly]))
        #expect(
            failureDetailFingerprint(["a": .actualOnly])
                != failureDetailFingerprint(["a": .verdictOnly]))
    }

    // MARK: - Data export

    @Test func exportedResultsAreMaskedWithTheGivenSettings() throws {
        let collection = wrMakeCollection(submissionID: "sub_x", outcomes: outcomes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(collection)
        let json = try #require(String(data: encoded, encoding: .utf8))

        let student = try #require(
            tierFilteredCollectionData(
                collectionJSON: json, visibleTiers: ["public"],
                failureDetailByFilename: detailMap))
        let studentText = try #require(String(data: student, encoding: .utf8))
        #expect(studentText.contains("GOT_A"))
        #expect(!studentText.contains("ANSWER_A"))
        #expect(!studentText.contains("ANSWER_B"))
        #expect(studentText.contains("ANSWER_C"))

        // Staff resolve an empty map: the full text.
        let staff = try #require(
            tierFilteredCollectionData(
                collectionJSON: json, visibleTiers: ["public"], failureDetailByFilename: [:]))
        let staffText = try #require(String(data: staff, encoding: .utf8))
        #expect(staffText.contains("ANSWER_A"))
        #expect(staffText.contains("ANSWER_B"))
    }

    // MARK: - GET /api/v1/submissions/:id/results

    @Test func resultsAPIMasksForStudentsAndNotForStaff() async throws {
        try await withWebRoutesApp { app in
            let studentCookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "setup_fdapi", manifest: manifest(bDetail: .verdictOnly), on: app)
            _ = try await wrInsertAssignment(
                testSetupID: "setup_fdapi", title: "Detail API Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_fdapi", testSetupID: "setup_fdapi", userID: student.requireID(), on: app)
            try await wrInsertResult(submissionID: "sub_fdapi", outcomes: outcomes, on: app)

            var studentETag: String?
            try await app.asyncTest(
                .GET, "/api/v1/submissions/sub_fdapi/results",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("GOT_A"))
                    #expect(!body.contains("ANSWER_A"))
                    #expect(!body.contains("ANSWER_B"))
                    #expect(!body.contains("GOT_B"))
                    #expect(body.contains("did not pass"))
                    #expect(body.contains("ANSWER_C"), "a pass is never masked")
                    studentETag = res.headers.first(name: .eTag)
                })

            // Relaxing the setting re-serves the past result in full.
            let setup = try #require(try await APITestSetup.find("setup_fdapi", on: app.db))
            setup.manifest = manifest(bDetail: .full)
            try await setup.save(on: app.db)
            let staleETag = try #require(studentETag)
            try await app.asyncTest(
                .GET, "/api/v1/submissions/sub_fdapi/results",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: studentCookie)
                    req.headers.add(name: .ifNoneMatch, value: staleETag)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "a changed setting must not answer 304")
                    let body = res.body.string
                    #expect(body.contains("ANSWER_B"))
                    #expect(!body.contains("ANSWER_A"), "publictest_a is still actualOnly")
                })

            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await app.asyncTest(
                .GET, "/api/v1/submissions/sub_fdapi/results",
                beforeRequest: { req in req.headers.add(name: .cookie, value: instructorCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("ANSWER_A"), "staff always read the full text")
                })
        }
    }
}
