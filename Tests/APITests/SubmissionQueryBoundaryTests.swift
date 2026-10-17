// Tests/APITests/SubmissionQueryBoundaryTests.swift
//
// The edges of the two query parameters on the submissions API that a caller
// controls: `?limit=` / `?offset=` on `GET /api/v1/submissions`, and `?tiers=`
// on `GET /api/v1/submissions/:id/results`.
//
// `SubmissionQueryRoutesTests` covers the ordinary values. These tests cover
// the values a client sends by mistake or on purpose: zero, negative, not a
// number, beyond the cap, at the integer limit, and a tier the caller may not
// see.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class SubmissionQueryBoundaryTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-sq-bounds")
    }

    // MARK: - Fixture

    /// A student with three submissions to one worker-graded assignment that is
    /// due tomorrow, so release and secret output are still hidden from them.
    private func studentWithThreeSubmissions() async throws -> (cookie: String, submissionIDs: [String]) {
        let course = try await makeTestCourse(on: app, code: "BOUND1")
        let courseID = try course.requireID()
        let setupID = "setup_bounds"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID,
            manifest:
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
        )
        try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, dueAt: Date().addingTimeInterval(86_400))

        let cookie = try await loginAsStudent("bounds_student", on: app)
        let student = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "bounds_student").first())
        _ = try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: courseID)

        var ids: [String] = []
        for index in 1...3 {
            let id = "sub_bounds_\(index)"
            try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: try student.requireID())
            ids.append(id)
        }
        return (cookie, ids)
    }

    private func list(query: String, cookie: String) async throws -> (status: HTTPStatus, size: Int?) {
        var status: HTTPStatus = .ok
        var size: Int?
        try await app.asyncTest(
            .GET, "/api/v1/submissions?\(query)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                status = res.status
                size = try? res.content.decode(SubmissionListResponse.self).submissions.count
            })
        return (status, size)
    }

    // MARK: - Pagination

    @Test(arguments: [
        ("limit=0", 1),
        ("limit=-5", 1),
        ("limit=two", 3),
        ("limit=99999", 3),
        ("offset=-1", 3),
        ("offset=many", 3),
        ("limit=1&offset=2", 1),
        ("limit=1&offset=3", 0),
    ])
    func paginationClampsWhatTheCallerSends(query: String, expected: Int) async throws {
        try await withApp(app) { _ in
            let fixture = try await studentWithThreeSubmissions()

            let response = try await list(query: query, cookie: fixture.cookie)

            #expect(response.status == .ok)
            #expect(response.size == expected)
        }
    }

    /// An offset at the integer limit once overflowed `offset + limit`, which
    /// traps and takes the whole server process down. It must read as an empty
    /// page.
    @Test(arguments: [Int.max, Int.max - 1, Int.max - 5_000])
    func anOffsetAtTheIntegerLimitIsAnEmptyPage(offset: Int) async throws {
        try await withApp(app) { _ in
            let fixture = try await studentWithThreeSubmissions()

            let response = try await list(query: "offset=\(offset)", cookie: fixture.cookie)

            #expect(response.status == .ok)
            #expect(response.size == .some(.zero))
        }
    }

    // MARK: - Tier slices

    private func storeResult(for submissionID: String) async throws {
        let outcomes = [TestTier.pub, .release, .secret].map { tier in
            TestOutcome(
                testName: "test_\(tier.rawValue)", testClass: nil, tier: tier, status: .pass,
                shortResult: "passed", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
                attemptNumber: 1, isFirstPassSuccess: false)
        }
        let collection = TestOutcomeCollection(
            submissionID: submissionID, testSetupID: "setup_bounds", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: outcomes,
            totalTests: 3, passCount: 3, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 3, runnerVersion: "test", timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: encoder.encode(collection), encoding: .utf8))
        try await APIResult(id: "res_\(submissionID)", submissionID: submissionID)
            .saveWithCollection(json: json, on: app.db)
    }

    private func outcomeTiers(
        submissionID: String, tiers: String, cookie: String
    ) async throws -> (status: HTTPStatus, tiers: Set<TestTier>?) {
        var status: HTTPStatus = .ok
        var seen: Set<TestTier>?
        try await app.asyncTest(
            .GET, "/api/v1/submissions/\(submissionID)/results?tiers=\(tiers)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                status = res.status
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let body = try? decoder.decode(TestOutcomeCollection.self, from: Data(res.body.readableBytesView)) {
                    seen = Set(body.outcomes.map(\.tier))
                }
            })
        return (status, seen)
    }

    /// The response must decode, so an empty set means "nothing selected"
    /// and never "nothing parsed". `public` is the positive control.
    @Test(arguments: [
        ("public", Set([TestTier.pub])),
        ("release", Set<TestTier>()),
        ("secret", Set<TestTier>()),
        ("release,secret", Set<TestTier>()),
        ("public,release,secret", Set([TestTier.pub])),
    ])
    func aStudentCannotNameAHiddenTierIntoView(tiers: String, expected: Set<TestTier>) async throws {
        try await withApp(app) { _ in
            let fixture = try await studentWithThreeSubmissions()
            let submissionID = try #require(fixture.submissionIDs.first)
            try await storeResult(for: submissionID)

            let response = try await outcomeTiers(submissionID: submissionID, tiers: tiers, cookie: fixture.cookie)

            #expect(response.status == .ok)
            let seen = try #require(response.tiers, "the response decodes as a collection")
            #expect(seen == expected, "release and secret stay hidden before the deadline")
        }
    }

    @Test(arguments: ["bogus", "", ",", "PUBLIC"])
    func aTierNameTheServerDoesNotKnowSelectsNothing(tiers: String) async throws {
        try await withApp(app) { _ in
            let fixture = try await studentWithThreeSubmissions()
            let submissionID = try #require(fixture.submissionIDs.first)
            try await storeResult(for: submissionID)

            let response = try await outcomeTiers(submissionID: submissionID, tiers: tiers, cookie: fixture.cookie)

            #expect(response.status == .ok)
            let seen = try #require(response.tiers, "the response decodes as a collection")
            #expect(seen.isEmpty)
        }
    }
}
