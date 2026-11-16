// LoadTest/HTTPExchange.swift
//
// One request and its whole response for the lecture run. The hot-path run
// keeps its own `LoadRun.send`, which needs only the status of a small
// reply. This one reads a body of any size (a kernel package is tens of
// megabytes) while keeping only the first bytes the caller needs, and it
// returns the headers, because the lecture run reads cookies, ETags and
// redirects.

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

struct HTTPReply: Sendable {
    let status: Int
    let headers: HTTPHeaders
    /// The first bytes of the body, up to the limit the caller asked for.
    let body: Data
    /// Every byte the response carried.
    let byteCount: Int

    var text: String { String(bytes: body, encoding: .utf8) ?? "" }

    func header(_ name: String) -> String? {
        headers.first(name: name)
    }
}

struct HTTPExchange: Sendable {
    let client: HTTPClient

    /// Sends the request and reads the whole response. `keep` bounds the
    /// body bytes held in memory; the rest are counted and dropped.
    func send(
        _ method: HTTPMethod,
        _ url: String,
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        keep: Int = 0
    ) async throws -> HTTPReply {
        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers = headers
        if let body {
            request.body = .bytes(body)
        }
        let response = try await client.execute(request, timeout: .seconds(120))
        var kept = Data()
        var total = 0
        for try await chunk in response.body {
            total += chunk.readableBytes
            if kept.count < keep {
                kept.append(contentsOf: chunk.readableBytesView.prefix(keep - kept.count))
            }
        }
        return HTTPReply(status: Int(response.status.code), headers: response.headers, body: kept, byteCount: total)
    }

    /// A client for a lecture run: redirects are not followed (a sign-in
    /// redirect is a result to report, and the provisioning reads its
    /// `Location`), and the pool may open as many connections as the
    /// simulated browsers would.
    static func makeClient(connectionsPerHost: Int) -> HTTPClient {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = max(8, connectionsPerHost)
        configuration.timeout = .init(connect: .seconds(10), read: .seconds(120))
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }
}
