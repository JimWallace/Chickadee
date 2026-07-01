// Tests/APITests/BrightSpaceVerbDispatchTests.swift
//
// #1105 — the wire verb `sendSigned` emits must match the verb inside the
// Valence signature. D2L verifies the method as part of the signature, so a
// mismatch is a guaranteed 403: `clearGrade` used to sign a DELETE that the
// transport dispatched as a GET, so grade removal could never work against a
// real LMS, and the in-memory fake the sync tests use could not see it.
// These tests stub `app.client`, capture what the real `BrightSpaceAPIClient`
// actually sends, and recompute the signature from the captured URL's own
// x_t/x_c parameters for the captured verb.

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A `Client` stub that records every outgoing request and answers 200 with
/// an empty body.
private final class CapturingClient: Client, Sendable {
    struct Sent: Sendable {
        let method: HTTPMethod
        let url: String
    }

    let eventLoop: EventLoop
    let sent: NIOLockedValueBox<[Sent]>

    init(eventLoop: EventLoop, sent: NIOLockedValueBox<[Sent]>) {
        self.eventLoop = eventLoop
        self.sent = sent
    }

    func delegating(to eventLoop: EventLoop) -> Client {
        CapturingClient(eventLoop: eventLoop, sent: sent)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        sent.withLockedValue { $0.append(Sent(method: request.method, url: request.url.string)) }
        return eventLoop.makeSucceededFuture(ClientResponse(status: .ok, headers: [:], body: nil))
    }
}

@Suite(.serialized) final class BrightSpaceVerbDispatchTests {

    let app: Application
    fileprivate let sent = NIOLockedValueBox<[CapturingClient.Sent]>([])

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bs-verb")
        let box = sent
        app.clients.use { app in
            CapturingClient(eventLoop: app.eventLoopGroup.next(), sent: box)
        }
    }

    private static let config = BrightSpaceSyncConfig(
        baseURL: "https://learn.example",
        appID: "test-app-id",
        appKey: "test-app-key",
        userID: "test-user-id",
        userKey: "test-user-key",
        debounceSecs: 90
    )

    /// Asserts the captured request matching `urlContains` was sent with
    /// `method` AND that its own x_c signature verifies for that same method —
    /// i.e. the verb on the wire is the verb that was signed.
    private func expectVerbSignedAndSent(
        method: HTTPMethod, urlContains: String
    ) throws {
        let request = try #require(
            sent.withLockedValue { $0 }.first { $0.url.contains(urlContains) },
            "no captured request matching '\(urlContains)'")
        #expect(request.method == method, "wire verb for \(urlContains) is \(request.method)")

        let components = try #require(URLComponents(string: request.url))
        let query = components.queryItems ?? []
        let xc = try #require(query.first { $0.name == "x_c" }?.value)
        let xt = try #require(query.first { $0.name == "x_t" }?.value.flatMap(Int.init))
        let base = valenceRequestBaseString(
            method: request.method.rawValue, path: valencePath(of: request.url), timestamp: xt)
        let key = SymmetricKey(data: Data(Self.config.appKey.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(base.utf8), using: key)
        #expect(
            Data(mac).base64URLEncodedString() == xc,
            "x_c signature does not verify for wire verb \(request.method) — verb/signature mismatch")
    }

    @Test func clearGradeSendsSignedDELETE() async throws {
        try await withApp(app) { app in
            let client = BrightSpaceAPIClient(config: Self.config)
            try await client.clearGrade(
                orgUnitID: "111", gradeObjectID: "222", bsUserID: "333", on: app)
            try expectVerbSignedAndSent(method: .DELETE, urlContains: "/grades/222/values/333")
            // The version negotiation that preceded it goes as a signed GET.
            try expectVerbSignedAndSent(method: .GET, urlContains: "/d2l/api/le/versions/")
        }
    }

    @Test func pushGradeSendsSignedPUT() async throws {
        try await withApp(app) { app in
            let client = BrightSpaceAPIClient(config: Self.config)
            try await client.pushGrade(
                orgUnitID: "111", gradeObjectID: "222", bsUserID: "333",
                earnedPoints: 7.5, on: app)
            try expectVerbSignedAndSent(method: .PUT, urlContains: "/grades/222/values/333")
        }
    }
}
