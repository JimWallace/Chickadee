// Tests/APITests/BrightSpace/BrightSpaceClientNegotiationTests.swift
//
// The request layer of the real `BrightSpaceAPIClient`, against a scripted
// `app.client`: the API version negotiation (pin, cache and fallback), the
// one clock-skew retry after a "Timestamp out of range" 403, the default
// group readers of the `BrightSpaceGrading` protocol, and the capped body
// read that the error paths use. No request reaches the network.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct BrightSpaceClientNegotiationTests {

    private static func versionRequests(_ sent: NIOLockedValueBox<[ScriptedValenceRequest]>) -> Int {
        sent.withLockedValue { $0 }.filter { $0.url.contains("/versions/") }.count
    }

    private static func gradeURLs(_ sent: NIOLockedValueBox<[ScriptedValenceRequest]>) -> [String] {
        sent.withLockedValue { $0 }.filter { $0.url.contains("/grades/") }.map(\.url)
    }

    // MARK: - Version negotiation

    @Test func theAdvertisedVersionIsUsedAndCached() async throws {
        let script: ScriptedValenceClient.Script = { _, url, _ in
            url.contains("/le/versions/")
                ? ScriptedValenceReply(.ok, #"{"ProductCode": "le", "LatestVersion": " 1.80 "}"#)
                : ScriptedValenceReply(.ok)
        }
        try await withScriptedValence(script) { client, app, sent in
            try await client.pushGrade(
                orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 4, on: app)
            try await client.clearGrade(orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", on: app)
            let urls = Self.gradeURLs(sent)
            #expect(urls.count == 2)
            #expect(urls.allSatisfy { $0.contains("/d2l/api/le/1.80/1/grades/2/values/3") })
            #expect(Self.versionRequests(sent) == 1)
        }
    }

    @Test func aBlankAdvertisedVersionFallsBackAndIsCached() async throws {
        let script: ScriptedValenceClient.Script = { _, url, _ in
            url.contains("/le/versions/")
                ? ScriptedValenceReply(.ok, #"{"LatestVersion": "   "}"#)
                : ScriptedValenceReply(.ok)
        }
        try await withScriptedValence(script) { client, app, sent in
            try await client.pushGrade(
                orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 4, on: app)
            try await client.pushGrade(
                orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 5, on: app)
            #expect(Self.gradeURLs(sent).allSatisfy { $0.contains("/le/\(BrightSpaceSyncConfig.leAPIVersion)/") })
            #expect(Self.versionRequests(sent) == 1)
        }
    }

    @Test(arguments: [
        ScriptedValenceReply(.ok, "not json"),
        ScriptedValenceReply(.notFound),
    ])
    func aFailedDiscoveryFallsBackAndIsAskedAgain(reply: ScriptedValenceReply) async throws {
        let script: ScriptedValenceClient.Script = { _, url, _ in
            url.contains("/versions/") ? reply : ScriptedValenceReply(.ok)
        }
        try await withScriptedValence(script) { client, app, sent in
            try await client.clearGrade(orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", on: app)
            try await client.clearGrade(orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", on: app)
            #expect(Self.gradeURLs(sent).allSatisfy { $0.contains("/le/\(BrightSpaceSyncConfig.leAPIVersion)/") })
            #expect(Self.versionRequests(sent) == 2)
        }
    }

    @Test func anEnvironmentPinWinsOverDiscovery() async throws {
        try await withTestEnvironment(["BRIGHTSPACE_LE_API_VERSION": " 1.99 "]) {
            let script: ScriptedValenceClient.Script = { _, url, _ in
                url.contains("/versions/")
                    ? ScriptedValenceReply(.ok, #"{"LatestVersion": "1.80"}"#)
                    : ScriptedValenceReply(.ok)
            }
            try await withScriptedValence(script) { client, app, sent in
                try await client.pushGrade(
                    orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 4, on: app)
                #expect(Self.gradeURLs(sent).allSatisfy { $0.contains("/d2l/api/le/1.99/") })
                #expect(Self.versionRequests(sent) == 0)
            }
        }
    }

    // MARK: - Clock-skew retry

    @Test func aTimestampErrorTeachesTheSkewAndRetriesOnce() async throws {
        let serverTime = 1_700_000_000
        let script: ScriptedValenceClient.Script = { method, _, index in
            guard method == .PUT else { return ScriptedValenceReply(.notFound) }
            return index == 1
                ? ScriptedValenceReply(.forbidden, "Timestamp out of range\r\n\(serverTime)")
                : ScriptedValenceReply(.ok)
        }
        try await withScriptedValence(script) { client, app, sent in
            try await client.pushGrade(
                orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 4, on: app)
            let puts = sent.withLockedValue { $0 }.filter { $0.method == .PUT }
            #expect(puts.count == 2)
            let firstStamp = try #require(puts.first?.signedTimestamp)
            let retryStamp = try #require(puts.last?.signedTimestamp)
            #expect(abs(firstStamp - Int(Date().timeIntervalSince1970)) < 60)
            #expect(abs(retryStamp - serverTime) < 60)

            // The learned skew stays on the client for later requests.
            try await client.clearGrade(orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", on: app)
            let delete = try #require(sent.withLockedValue { $0 }.last { $0.method == .DELETE })
            let deleteStamp = try #require(delete.signedTimestamp)
            #expect(abs(deleteStamp - serverTime) < 60)
        }
    }

    @Test(arguments: ["Not authorized", "Timestamp out of range"])
    func anotherForbiddenIsNotRetried(body: String) async throws {
        let script: ScriptedValenceClient.Script = { method, _, _ in
            method == .PUT ? ScriptedValenceReply(.forbidden, body) : ScriptedValenceReply(.notFound)
        }
        try await withScriptedValence(script) { client, app, sent in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.pushGrade(
                    orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 4, on: app)
            }
            #expect(error?.description.hasPrefix("BrightSpace grade push failed (HTTP 403)") == true)
            #expect(error?.httpStatus == 403)
            #expect(error?.responseBody == body)
            #expect(sent.withLockedValue { $0 }.filter { $0.method == .PUT }.count == 1)
        }
    }

    // MARK: - Protocol defaults

    private struct MinimalGrading: BrightSpaceGrading {
        func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? { nil }
        func fetchClasslist(
            orgUnitID: String, on application: Application
        ) async throws
            -> [BrightSpaceClasslistEntry]
        { [] }
        func pushGrade(
            orgUnitID: String, gradeObjectID: String, bsUserID: String, earnedPoints: Double,
            on application: Application
        ) async throws {}
        func fetchGradeObject(
            orgUnitID: String, gradeObjectID: String, on application: Application
        ) async throws -> BrightSpaceGradeObject? { nil }
        func clearGrade(
            orgUnitID: String, gradeObjectID: String, bsUserID: String, on application: Application
        ) async throws {}
    }

    @Test func aConformerWithoutGroupReadersReadsNoGroups() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            let grading: any BrightSpaceGrading = MinimalGrading()
            let groups = try await grading.fetchGroups(orgUnitID: "1", categoryID: "2", on: app)
            #expect(groups.isEmpty)
            let sections = try await grading.fetchSections(orgUnitID: "1", on: app)
            #expect(sections.isEmpty)
        }
    }

    // MARK: - Body read

    @Test func theBodyReadIsCappedAndLeavesTheBodyIntact() {
        let response = ClientResponse(status: .badRequest, headers: [:], body: ByteBuffer(string: "abcdef"))
        #expect(response.bodyString(max: 3) == "abc")
        #expect(response.bodyString() == "abcdef")
        #expect(response.body?.readableBytes == 6)
        #expect(ClientResponse(status: .badRequest, headers: [:], body: nil).bodyString().isEmpty)
        #expect(
            ClientResponse(status: .badRequest, headers: [:], body: ByteBuffer()).bodyString().isEmpty)
    }
}
