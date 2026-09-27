// Tests/APITests/LTI/LTIAGSClientTests.swift
//
// The AGS client against a stand-in LMS (docs/lti-1-3.md "Grades through
// AGS"): the token request and its signed assertion, token caching, line-item
// lookup and creation, score posting, and the URL and body rules.

import Core
import Foundation
import JWT
import Testing
import Vapor

@testable import APIServer

@Suite struct LTIAGSClientTests {
    static let platform = LTIAGSClient.Platform(
        id: UUID(), clientID: "chickadee-client", accessTokenURL: LTITestGradeService.tokenURL)

    private static func toolKey() async throws -> (LTIToolKeyAuthority, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-ags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys = try await LTIToolKeyAuthority.loadOrGenerate(path: directory.appendingPathComponent("key").path)
        return (keys, directory)
    }

    // MARK: - Line items

    @Test func createsTheLineItemWhenTheLMSHasNone() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()

        let url = try await lms.client.lineItemURL(
            resourceID: "abc123", label: "Lab 1", scoreMaximum: 10,
            lineItemsURL: LTITestGradeService.lineItemsURL, platform: Self.platform, keys: keys)

        #expect(url == LTITestGradeService.createdLineItemURL)
        let requests = await lms.requests
        #expect(requests.map(\.method) == [.POST, .GET, .POST])
        #expect(requests[1].url.contains("resource_id=abc123"))
        #expect(requests[1].authorization == "Bearer token-1")
        #expect(requests[2].contentType == LTIAGSClient.lineItemType)
        let created = try JSONDecoder().decode([String: JSONValue].self, from: Data(requests[2].body.utf8))
        #expect(created["resourceId"] == .string("abc123"))
        #expect(created["label"] == .string("Lab 1"))
        #expect(requests[2].body.contains(#""scoreMaximum":10"#))
    }

    @Test func reusesTheLineItemTheLMSAlreadyHas() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()
        await lms.addExistingLineItem(resourceID: "other", url: "https://lms.example.edu/items/1")
        await lms.addExistingLineItem(resourceID: "abc123", url: "https://lms.example.edu/items/2")

        let url = try await lms.client.lineItemURL(
            resourceID: "abc123", label: "Lab 1", scoreMaximum: 10,
            lineItemsURL: LTITestGradeService.lineItemsURL, platform: Self.platform, keys: keys)

        #expect(url == "https://lms.example.edu/items/2")
        #expect(await lms.requests.map(\.method) == [.POST, .GET])
    }

    // MARK: - Tokens

    @Test func theTokenRequestCarriesAnAssertionSignedByTheToolKey() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()

        try await lms.client.postScore(
            .graded(userID: "subject-1", points: 7, maximum: 10, at: Date()),
            lineItemURL: LTITestGradeService.createdLineItemURL, platform: Self.platform, keys: keys)

        let tokenRequest = try #require(await lms.requests.first)
        #expect(tokenRequest.url == LTITestGradeService.tokenURL)
        #expect(tokenRequest.contentType == "application/x-www-form-urlencoded")
        var form: [String: String] = [:]
        for pair in tokenRequest.body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            form[parts[0]] = parts[1].removingPercentEncoding
        }
        #expect(form["grant_type"] == "client_credentials")
        #expect(form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(form["scope"] == LTIAGSClient.scopes.joined(separator: " "))
        let assertion = try await keys.verify(try #require(form["client_assertion"]), as: LTIClientAssertion.self)
        #expect(assertion.iss.value == "chickadee-client")
        #expect(assertion.sub.value == "chickadee-client")
        #expect(assertion.aud.value == [LTITestGradeService.tokenURL])
    }

    @Test func aTokenIsFetchedOnceAndReused() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()
        let client = await lms.client
        let score = LTIScore.graded(userID: "subject-1", points: 7, maximum: 10, at: Date())

        for _ in 0..<3 {
            try await client.postScore(
                score, lineItemURL: LTITestGradeService.createdLineItemURL, platform: Self.platform, keys: keys)
        }

        let tokenRequests = await lms.requests.filter { $0.url == LTITestGradeService.tokenURL }
        #expect(tokenRequests.count == 1)
    }

    @Test func anUnauthorizedAnswerDropsTheCachedToken() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()
        let client = await lms.client
        let score = LTIScore.graded(userID: "subject-1", points: 7, maximum: 10, at: Date())

        await lms.refuseNextScore(with: .unauthorized)
        await #expect(throws: LTIAGSError.rejected(.postScore, status: 401)) {
            try await client.postScore(
                score, lineItemURL: LTITestGradeService.createdLineItemURL, platform: Self.platform, keys: keys)
        }
        try await client.postScore(
            score, lineItemURL: LTITestGradeService.createdLineItemURL, platform: Self.platform, keys: keys)

        let tokenRequests = await lms.requests.filter { $0.url == LTITestGradeService.tokenURL }
        #expect(tokenRequests.count == 2)
        #expect(await lms.requests.last?.authorization == "Bearer token-2")
    }

    // MARK: - Scores

    @Test func aScoreGoesToTheLineItemScoresEndpoint() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()

        try await lms.client.postScore(
            .graded(userID: "subject-1", points: 7, maximum: 10, at: Date()),
            lineItemURL: LTITestGradeService.createdLineItemURL, platform: Self.platform, keys: keys)

        let scoreRequest = try #require(await lms.requests.last)
        #expect(scoreRequest.url == LTITestGradeService.createdLineItemURL + "/scores")
        #expect(scoreRequest.contentType == LTIAGSClient.scoreType)
        let score = try #require(await lms.scores.first)
        #expect(score.userId == "subject-1")
        #expect(score.scoreGiven == 7)
        #expect(score.scoreMaximum == 10)
        #expect(score.gradingProgress == "FullyGraded")
    }

    @Test func aDeletedLineItemIsReportedAsGone() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()
        await lms.refuseNextScore(with: .notFound)

        await #expect(throws: LTIAGSError.lineItemGone) {
            try await lms.client.postScore(
                .graded(userID: "subject-1", points: 7, maximum: 10, at: Date()),
                lineItemURL: LTITestGradeService.createdLineItemURL, platform: Self.platform, keys: keys)
        }
    }

    // MARK: - Wire rules

    @Test func theScoresURLKeepsTheLineItemQuery() {
        #expect(
            LTIAGSClient.scoresURL(forLineItem: "https://lms.example.edu/items/2?type=x")
                == "https://lms.example.edu/items/2/scores?type=x")
        #expect(
            LTIAGSClient.scoresURL(forLineItem: "https://lms.example.edu/items/2/")
                == "https://lms.example.edu/items/2/scores")
    }

    @Test func theResourceFilterKeepsTheLineItemsQuery() {
        let url = LTIAGSClient.url("https://lms.example.edu/items?type=x", addingResourceID: "abc")
        #expect(url == "https://lms.example.edu/items?type=x&resource_id=abc")
    }

    @Test func aClearingScoreSendsNoGrade() throws {
        let data = try JSONEncoder().encode(LTIScore.cleared(userID: "subject-1", at: Date()))
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(fields["scoreGiven"] == nil)
        #expect(fields["scoreMaximum"] == nil)
        #expect(fields["gradingProgress"] == .string("NotReady"))
        #expect(fields["activityProgress"] == .string("Initialized"))
    }

    @Test func theLineItemsURLNeedsBothScopes() {
        let url = "https://lms.example.edu/items"
        let both = LTIAGSEndpoint(
            scope: [LTIAGSEndpoint.lineItemScope, LTIAGSEndpoint.scoreScope], lineItems: url, lineItem: nil)
        let scoreOnly = LTIAGSEndpoint(scope: [LTIAGSEndpoint.scoreScope], lineItems: url, lineItem: nil)
        #expect(both.usableLineItemsURL == url)
        #expect(scoreOnly.usableLineItemsURL == nil)
    }

    @Test func onlyRecoverableFailuresAreRetried() {
        #expect(LTIAGSError.rejected(.postScore, status: 503).isRetryable)
        #expect(LTIAGSError.rejected(.token, status: 429).isRetryable)
        #expect(LTIAGSError.lineItemGone.isRetryable)
        #expect(!LTIAGSError.rejected(.postScore, status: 400).isRetryable)
        #expect(!LTIAGSError.rejected(.token, status: 403).isRetryable)
        #expect(!LTIAGSError.unreadableResponse(.token).isRetryable)
    }
}
