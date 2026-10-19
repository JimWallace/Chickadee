// Tests/APITests/BrightSpace/BrightSpaceGroupReaderTests.swift
//
// The LEARN group readers decode what Valence sends (docs/lab-groups.md,
// slice 6). The Sections, group-category and group lists return a bare JSON
// array, not a paging envelope, so a reader that expects an envelope fails on
// every real course. These tests stub `app.client` with the documented
// shapes and drive the real `BrightSpaceAPIClient`.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A `Client` stub that answers each request with the body of the first
/// route its path contains, and 404 for any other path (the version
/// negotiation then falls back to the pinned version).
private final class ValenceStub: Client, Sendable {
    let eventLoop: any EventLoop
    let routes: [(path: String, body: String)]
    let sent: NIOLockedValueBox<[String]>

    init(eventLoop: any EventLoop, routes: [(path: String, body: String)], sent: NIOLockedValueBox<[String]>) {
        self.eventLoop = eventLoop
        self.routes = routes
        self.sent = sent
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        ValenceStub(eventLoop: eventLoop, routes: routes, sent: sent)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let url = request.url.string
        sent.withLockedValue { $0.append(url) }
        guard let route = routes.first(where: { url.contains($0.path) }) else {
            return eventLoop.makeSucceededFuture(ClientResponse(status: .notFound, headers: [:], body: nil))
        }
        let headers = HTTPHeaders([("Content-Type", "application/json")])
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: .ok, headers: headers, body: ByteBuffer(string: route.body)))
    }
}

@Suite(.serialized) final class BrightSpaceGroupReaderTests {

    let app: Application
    private let sent = NIOLockedValueBox<[String]>([])

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bs-groups")
        let box = sent
        let routes: [(path: String, body: String)] = [
            (
                "/900/sections/",
                #"""
                [{"SectionId": 70, "Name": "Lab 101", "Code": "L101",
                  "Description": {"Text": "", "Html": ""}, "Enrollments": [501, 502]}]
                """#
            ),
            (
                "/groupcategories/77/groups/",
                #"""
                [{"GroupId": 300, "Name": "Team A", "Code": "A",
                  "Description": {"Text": "", "Html": ""}, "Enrollments": [503]}]
                """#
            ),
            (
                "/900/groupcategories/",
                #"""
                [{"GroupCategoryId": 77, "Name": "Teams", "Description": {"Text": "", "Html": ""},
                  "EnrollmentStyle": 0, "EnrollmentQuantity": null, "MaxUsersPerGroup": null,
                  "AutoEnroll": false, "RandomizeEnrollments": false, "Groups": [300],
                  "AllocateAfterExpiry": false, "SelfEnrollmentExpiryDate": null}]
                """#
            ),
        ]
        app.clients.use { app in ValenceStub(eventLoop: app.eventLoopGroup.next(), routes: routes, sent: box) }
    }

    private static let config = BrightSpaceSyncConfig(
        baseURL: "https://learn.example",
        appID: "test-app-id",
        appKey: "test-app-key",
        userID: "test-user-id",
        userKey: "test-user-key",
        debounceSecs: 90
    )

    @Test func theSectionsReaderDecodesTheBareArray() async throws {
        try await withApp(app) { app in
            let sections = try await BrightSpaceAPIClient(config: Self.config).fetchSections(orgUnitID: "900", on: app)
            #expect(sections.map(\.groupID) == ["70"])
            #expect(sections.map(\.name) == ["Lab 101"])
            #expect(sections.map(\.enrollments) == [["501", "502"]])
            #expect(
                sent.withLockedValue { $0 }.contains { $0.contains("/d2l/api/lp/") && $0.contains("/900/sections/") })
        }
    }

    @Test func theGroupReadersDecodeTheBareArray() async throws {
        try await withApp(app) { app in
            let client = BrightSpaceAPIClient(config: Self.config)
            let categories = try await client.fetchGroupCategories(orgUnitID: "900", on: app)
            #expect(categories.map(\.categoryID) == ["77"])
            #expect(categories.map(\.name) == ["Teams"])
            let groups = try await client.fetchGroups(orgUnitID: "900", categoryID: "77", on: app)
            #expect(groups.map(\.groupID) == ["300"])
            #expect(groups.map(\.enrollments) == [["503"]])
        }
    }

    @Test func aFailedSectionsReadThrowsItsOwnError() async throws {
        try await withApp(app) { app in
            let error = await #expect(throws: BrightSpaceSyncError.self) {
                try await BrightSpaceAPIClient(config: Self.config).fetchSections(orgUnitID: "901", on: app)
            }
            #expect(error?.description == "BrightSpace sections fetch for org unit '901' failed (HTTP 404)")
        }
    }
}
