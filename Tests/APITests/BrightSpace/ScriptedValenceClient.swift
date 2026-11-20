// Tests/APITests/BrightSpace/ScriptedValenceClient.swift
//
// A `Client` stub for the BrightSpace API client tests. Each request goes to
// a script that picks the status and the body from the verb and the URL. The
// stub records every request, so a test can check what the real
// `BrightSpaceAPIClient` sent. No request reaches the network.
//
// `BrightSpaceVerbDispatchTests` and `BrightSpaceGroupReaderTests` keep their
// own private stubs. This one is shared and scriptable per request (verb, URL
// and request index), which the error-mapping and clock-skew tests need. The
// older suites can move to it later.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

@testable import APIServer

/// One answer from the script: a status and an optional JSON body.
struct ScriptedValenceReply: Sendable {
    let status: HTTPResponseStatus
    let body: String?

    init(_ status: HTTPResponseStatus, _ body: String? = nil) {
        self.status = status
        self.body = body
    }
}

/// One request the stub received.
struct ScriptedValenceRequest: Sendable {
    let method: HTTPMethod
    let url: String
}

final class ScriptedValenceClient: Client, Sendable {
    typealias Script = @Sendable (_ method: HTTPMethod, _ url: String, _ index: Int) -> ScriptedValenceReply

    let eventLoop: any EventLoop
    let script: Script
    let sent: NIOLockedValueBox<[ScriptedValenceRequest]>

    init(eventLoop: any EventLoop, sent: NIOLockedValueBox<[ScriptedValenceRequest]>, script: @escaping Script) {
        self.eventLoop = eventLoop
        self.sent = sent
        self.script = script
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        ScriptedValenceClient(eventLoop: eventLoop, sent: sent, script: script)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let url = request.url.string
        let index = sent.withLockedValue { list in
            list.append(ScriptedValenceRequest(method: request.method, url: url))
            return list.count - 1
        }
        let reply = script(request.method, url, index)
        var headers = HTTPHeaders()
        let body = reply.body.map { ByteBuffer(string: $0) }
        if body != nil { headers.add(name: .contentType, value: "application/json") }
        return eventLoop.makeSucceededFuture(ClientResponse(status: reply.status, headers: headers, body: body))
    }
}

extension Application {
    /// Routes `app.client` to a `ScriptedValenceClient` and returns the box
    /// that records each request.
    func useScriptedValence(
        _ script: @escaping ScriptedValenceClient.Script
    ) -> NIOLockedValueBox<[ScriptedValenceRequest]> {
        let box = NIOLockedValueBox<[ScriptedValenceRequest]>([])
        clients.use { app in
            ScriptedValenceClient(eventLoop: app.eventLoopGroup.next(), sent: box, script: script)
        }
        return box
    }
}

extension BrightSpaceSyncConfig {
    /// A fixed configuration for the stubbed client tests.
    static let scriptedTest = BrightSpaceSyncConfig(
        baseURL: "https://learn.example",
        appID: "test-app-id",
        appKey: "test-app-key",
        userID: "test-user-id",
        userKey: "test-user-key",
        debounceSecs: 90
    )
}

/// Builds a bare testing app whose `app.client` is a `ScriptedValenceClient`,
/// then runs `body` with a fresh `BrightSpaceAPIClient`, the app and the box
/// of recorded requests. The app needs no database.
func withScriptedValence(
    _ script: @escaping ScriptedValenceClient.Script,
    _ body: (BrightSpaceAPIClient, Application, NIOLockedValueBox<[ScriptedValenceRequest]>) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    let sent = app.useScriptedValence(script)
    try await withApp(app) { app in
        try await body(BrightSpaceAPIClient(config: .scriptedTest), app, sent)
    }
}

extension ScriptedValenceRequest {
    /// The `x_t` timestamp the client signed this request with.
    var signedTimestamp: Int? {
        URLComponents(string: url)?.queryItems?.first { $0.name == "x_t" }?.value.flatMap(Int.init)
    }
}

extension BrightSpaceSyncError {
    /// The HTTP status a failed Valence call carries, or nil for a case that
    /// carries none.
    var httpStatus: Int? {
        switch self {
        case .userLookupFailed(_, let status), .gradePushFailed(let status, _), .whoamiFailed(let status, _),
            .orgUnitLookupFailed(_, let status), .gradeObjectsFetchFailed(_, let status),
            .classlistFetchFailed(_, let status), .groupCategoriesFetchFailed(_, let status),
            .groupsFetchFailed(_, _, let status), .sectionsFetchFailed(_, let status):
            return status
        default:
            return nil
        }
    }

    /// The response body a failed grade push or whoami carries.
    var responseBody: String? {
        switch self {
        case .gradePushFailed(_, let body), .whoamiFailed(_, let body):
            return body
        default:
            return nil
        }
    }
}
