// Tests/APITests/BrightSpace/BrightSpaceClientErrorMappingTests.swift
//
// How the real `BrightSpaceAPIClient` maps each Valence answer to a result
// or to its own `BrightSpaceSyncError` case: the user lookup, whoami, the
// org-unit and grade-object reads, the grade push and clear, the paged
// classlist and the group readers. A scripted `app.client` answers every
// request, and the version discovery gets a 404, so the fallback versions
// apply. No request reaches the network.

import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct BrightSpaceClientErrorMappingTests {

    /// A script that answers 404 to the version discovery and `reply` to
    /// every other request.
    private static func answering(_ reply: ScriptedValenceReply) -> ScriptedValenceClient.Script {
        { _, url, _ in url.contains("/versions/") ? ScriptedValenceReply(.notFound) : reply }
    }

    /// Runs `body` against a client whose every request, except the version
    /// discovery, gets `status` and `body`.
    private static func answer(
        _ status: HTTPResponseStatus,
        _ replyBody: String? = nil,
        _ body: (BrightSpaceAPIClient, Application, NIOLockedValueBox<[ScriptedValenceRequest]>) async throws -> Void
    ) async throws {
        try await withScriptedValence(answering(ScriptedValenceReply(status, replyBody)), body)
    }

    private static func calls(_ sent: NIOLockedValueBox<[ScriptedValenceRequest]>) -> [ScriptedValenceRequest] {
        sent.withLockedValue { $0 }.filter { !$0.url.contains("/versions/") }
    }

    // MARK: - Grade push and clear

    @Test func aRefusedPushCarriesItsStatusAndBody() async throws {
        try await Self.answer(.badRequest, "Comments are mandatory") { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.pushGrade(
                    orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", earnedPoints: 4, on: app)
            }
            #expect(error?.httpStatus == 400)
            #expect(error?.responseBody == "Comments are mandatory")
        }
    }

    @Test func aClearOfAnAbsentValueSucceeds() async throws {
        try await Self.answer(.notFound) { client, app, sent in
            try await client.clearGrade(orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", on: app)
            #expect(Self.calls(sent).map(\.method) == [.DELETE])
        }
    }

    @Test func aRefusedClearThrows() async throws {
        try await Self.answer(.internalServerError, "boom") { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.clearGrade(orgUnitID: "1", gradeObjectID: "2", bsUserID: "3", on: app)
            }
            #expect(error?.httpStatus == 500)
            #expect(error?.responseBody == "boom")
        }
    }

    // MARK: - User lookup

    @Test func anEmptyStudentNumberSendsNothing() async throws {
        try await Self.answer(.ok) { client, app, sent in
            let userID = try await client.lookupUserID(orgDefinedId: "", on: app)
            #expect(userID == nil)
            #expect(sent.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func theLookupReturnsTheFirstUserAndEncodesTheQuery() async throws {
        let body = #"{"Items": [{"UserId": 4242}, {"UserId": 99}], "PagingInfo": null}"#
        try await Self.answer(.ok, body) { client, app, sent in
            let userID = try await client.lookupUserID(orgDefinedId: "20 123", on: app)
            #expect(userID == "4242")
            let url = try #require(Self.calls(sent).first?.url)
            #expect(url.contains("/d2l/api/lp/\(BrightSpaceSyncConfig.lpAPIVersion)/users/?orgDefinedId=20%20123&x_a="))
        }
    }

    @Test func aLookupWithNoItemsFindsNoUser() async throws {
        try await Self.answer(.ok, #"{"Items": []}"#) { client, app, _ in
            let userID = try await client.lookupUserID(orgDefinedId: "20123", on: app)
            #expect(userID == nil)
        }
    }

    @Test func aRefusedLookupThrowsWithoutTheStudentNumber() async throws {
        try await Self.answer(.forbidden, "denied") { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.lookupUserID(orgDefinedId: "20123", on: app)
            }
            #expect(error?.httpStatus == 403)
            #expect(error?.description == "BrightSpace user lookup failed (HTTP 403)")
        }
    }

    // MARK: - whoami

    @Test(arguments: [
        (
            #"{"Identifier": "7", "FirstName": "Ada", "LastName": "Lovelace", "UniqueName": "alovelace"}"#,
            "Ada Lovelace"
        ),
        (#"{"Identifier": "7", "FirstName": "", "LastName": "Lovelace", "UniqueName": "alovelace"}"#, "Lovelace"),
        (#"{"Identifier": "7", "FirstName": "", "UniqueName": "alovelace"}"#, "alovelace"),
        (#"{"Identifier": "7"}"#, "7"),
    ])
    func whoamiNamesTheAccount(body: String, displayName: String) async throws {
        try await Self.answer(.ok, body) { client, app, sent in
            let identity = try await client.whoami(on: app)
            #expect(identity.identifier == "7")
            #expect(identity.displayName == displayName)
            #expect(Self.calls(sent).first?.url.contains("/users/whoami?") == true)
        }
    }

    @Test func aRefusedWhoamiKeepsAtMost500CharactersOfTheBody() async throws {
        let body = String(repeating: "x", count: 600)
        try await Self.answer(.unauthorized, body) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.whoami(on: app)
            }
            #expect(error?.httpStatus == 401)
            #expect(error?.responseBody?.count == 500)
        }
    }

    // MARK: - Org unit

    @Test func anOrgUnitIsDecoded() async throws {
        let body = #"{"Identifier": "900", "Name": "HLTH 230", "Code": "HLTH230-F26"}"#
        try await Self.answer(.ok, body) { client, app, sent in
            let info = try #require(try await client.getOrgUnit(orgUnitID: "900", on: app))
            #expect(info.identifier == "900")
            #expect(info.name == "HLTH 230")
            #expect(info.code == "HLTH230-F26")
            #expect(Self.calls(sent).first?.url.contains("/orgstructure/900?") == true)
        }
    }

    @Test func aMissingOrEmptyOrgUnitIsNil() async throws {
        try await Self.answer(.notFound) { client, app, sent in
            let orgUnit = try await client.getOrgUnit(orgUnitID: "900", on: app)
            #expect(orgUnit == nil)
            let orgUnitAgain = try await client.getOrgUnit(orgUnitID: "", on: app)
            #expect(orgUnitAgain == nil)
            #expect(Self.calls(sent).count == 1)
        }
    }

    @Test func aRefusedOrgUnitLookupThrows() async throws {
        try await Self.answer(.forbidden) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.getOrgUnit(orgUnitID: "900", on: app)
            }
            #expect(error?.description == "BrightSpace org unit lookup for '900' failed (HTTP 403)")
        }
    }

    // MARK: - Grade objects

    private static let gradeObject =
        #"{"Id": 55, "Name": "Lab 1", "MaxPoints": 10, "GradeType": "Numeric", "CanExceed": false}"#

    @Test func theGradeBookIsListed() async throws {
        try await Self.answer(.ok, "[\(Self.gradeObject)]") { client, app, sent in
            let items = try await client.listGradeObjects(orgUnitID: "900", on: app)
            #expect(items.map(\.id) == ["55"])
            #expect(items.map(\.maxPoints) == [10])
            #expect(items.map(\.gradeType) == ["Numeric"])
            let gradeBook = try await client.listGradeObjects(orgUnitID: "", on: app)
            #expect(gradeBook.isEmpty)
            #expect(Self.calls(sent).count == 1)
        }
    }

    @Test func aRefusedGradeBookListThrows() async throws {
        try await Self.answer(.serviceUnavailable) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.listGradeObjects(orgUnitID: "900", on: app)
            }
            #expect(error?.description == "BrightSpace grade-objects fetch for org unit '900' failed (HTTP 503)")
        }
    }

    @Test func oneGradeObjectIsDecoded() async throws {
        try await Self.answer(.ok, Self.gradeObject) { client, app, sent in
            let item = try #require(try await client.fetchGradeObject(orgUnitID: "900", gradeObjectID: "55", on: app))
            #expect(item.name == "Lab 1")
            #expect(item.canExceed == false)
            #expect(Self.calls(sent).first?.url.contains("/900/grades/55?") == true)
        }
    }

    @Test func aMissingGradeObjectOrAnEmptyIDIsNil() async throws {
        try await Self.answer(.notFound) { client, app, sent in
            let gradeItem = try await client.fetchGradeObject(orgUnitID: "900", gradeObjectID: "55", on: app)
            #expect(gradeItem == nil)
            let gradeItemAgain = try await client.fetchGradeObject(orgUnitID: "", gradeObjectID: "55", on: app)
            #expect(gradeItemAgain == nil)
            let gradeItemThird = try await client.fetchGradeObject(orgUnitID: "900", gradeObjectID: "", on: app)
            #expect(gradeItemThird == nil)
            #expect(Self.calls(sent).count == 1)
        }
    }

    @Test func aRefusedGradeObjectReadThrows() async throws {
        try await Self.answer(.internalServerError) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.fetchGradeObject(orgUnitID: "900", gradeObjectID: "55", on: app)
            }
            #expect(error?.httpStatus == 500)
        }
    }

    // MARK: - Classlist paging

    @Test func theClasslistFollowsTheBookmarkToTheLastPage() async throws {
        let first =
            #"{"Items": [{"Identifier": "1", "OrgDefinedId": "s1", "Username": "u1"}], "PagingInfo": {"Bookmark": "b1", "HasMoreItems": true}}"#
        let last =
            #"{"Objects": [{"Identifier": "2", "OrgDefinedId": "s2", "Username": "u2"}], "PagingInfo": {"Bookmark": "b2", "HasMoreItems": false}}"#
        let script: ScriptedValenceClient.Script = { _, url, _ in
            if url.contains("/versions/") { return ScriptedValenceReply(.notFound) }
            return ScriptedValenceReply(.ok, url.contains("bookmark=b1") ? last : first)
        }
        try await withScriptedValence(script) { client, app, sent in
            let roster = try await client.fetchClasslist(orgUnitID: "900", on: app)
            #expect(roster.map(\.userID) == ["1", "2"])
            #expect(roster.map(\.orgDefinedID) == ["s1", "s2"])
            #expect(roster.map(\.username) == ["u1", "u2"])
            #expect(Self.calls(sent).count == 2)
        }
    }

    @Test func aRefusedLaterPageFailsTheWholeClasslist() async throws {
        let first = #"{"Items": [{"Identifier": "1"}], "PagingInfo": {"Bookmark": "b1", "HasMoreItems": true}}"#
        let script: ScriptedValenceClient.Script = { _, url, _ in
            if url.contains("/versions/") { return ScriptedValenceReply(.notFound) }
            return url.contains("bookmark=b1") ? ScriptedValenceReply(.badGateway) : ScriptedValenceReply(.ok, first)
        }
        try await withScriptedValence(script) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.fetchClasslist(orgUnitID: "900", on: app)
            }
            #expect(error?.description == "BrightSpace classlist fetch for org unit '900' failed (HTTP 502)")
        }
    }

    @Test func anEmptyOrgUnitHasNoClasslist() async throws {
        try await Self.answer(.ok) { client, app, sent in
            let roster = try await client.fetchClasslist(orgUnitID: "", on: app)
            #expect(roster.isEmpty)
            #expect(sent.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func anUndecodableClasslistPageThrows() async throws {
        try await Self.answer(.ok, "<html>login</html>") { client, app, _ in
            await #expect(throws: (any Error).self) {
                try await client.fetchClasslist(orgUnitID: "900", on: app)
            }
        }
    }

    // MARK: - Group readers

    @Test func aRefusedGroupCategoryListThrowsItsOwnError() async throws {
        try await Self.answer(.forbidden) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.fetchGroupCategories(orgUnitID: "900", on: app)
            }
            #expect(error?.description == "BrightSpace group-categories fetch for org unit '900' failed (HTTP 403)")
        }
    }

    @Test func aRefusedGroupListThrowsItsOwnError() async throws {
        try await Self.answer(.notFound) { client, app, _ in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await client.fetchGroups(orgUnitID: "900", categoryID: "77", on: app)
            }
            #expect(
                error?.description
                    == "BrightSpace groups fetch for org unit '900' category '77' failed (HTTP 404)")
        }
    }

    @Test func emptyIDsReadNoGroups() async throws {
        try await Self.answer(.ok, "[]") { client, app, sent in
            let categories = try await client.fetchGroupCategories(orgUnitID: "", on: app)
            #expect(categories.isEmpty)
            let groups = try await client.fetchGroups(orgUnitID: "", categoryID: "77", on: app)
            #expect(groups.isEmpty)
            let groupsAgain = try await client.fetchGroups(orgUnitID: "900", categoryID: "", on: app)
            #expect(groupsAgain.isEmpty)
            let sections = try await client.fetchSections(orgUnitID: "", on: app)
            #expect(sections.isEmpty)
            #expect(sent.withLockedValue { $0 }.isEmpty)
        }
    }
}
