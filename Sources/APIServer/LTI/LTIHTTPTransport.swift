// APIServer/LTI/LTIHTTPTransport.swift
//
// The live HTTP transport for every call Chickadee makes to an LTI platform:
// the key set, the access token, AGS and NRPS
// (docs/compliance/lti-audit-2026-10.md L-4). The shared client's read
// timeout (`OutboundHTTPClientSetup`) ends a call only when a peer stops
// sending. A peer that sends one byte at a time, or a very large answer, would
// still hold a launch or the 60-second grade sweep. So each call here has one
// deadline for the whole call, body included, and the body is read only up to
// a size cap: the read stops once the stream passes the cap, before the whole
// body is in memory.
//
// AsyncHTTPClient's own `deadline` is not enough: it is cancelled once the
// response head arrives, so it does not cover the body. The deadline here
// races the whole call against a sleep, and cancelling the call cancels the
// request.
//
// It runs on Vapor's shared client, so the timeouts and the proxy that
// `OutboundHTTPClientSetup` sets still apply. The send closure of
// `LTIServiceClient` and the fetch of `LTIPlatformKeyCache` use it; their
// tests replace those closures, and `LTIHTTPTransportTests` tests it against
// a local server.

import AsyncHTTPClient
import NIOCore
import Vapor

enum LTIHTTPTransport {
    /// How long one call may take from start to the last byte of the body.
    static let callTimeout: Duration = .seconds(20)

    /// The largest body read from a platform. One NRPS page of a large class
    /// is a few hundred kilobytes; a key set or a token is far smaller.
    static let maximumBodyBytes = 4 * 1024 * 1024

    enum Failure: Error, Equatable {
        /// The body passed the size cap.
        case responseTooLarge
        /// The call did not finish within the deadline. Not an
        /// `LTIServiceError`, so the grade sweep retries it as it retries any
        /// transport error.
        case timedOut
    }

    /// Sends `request` and returns the answer with its body read in full,
    /// within `timeout` and `maximumBodyBytes`.
    static func send(
        _ request: ClientRequest, on client: HTTPClient,
        timeout: Duration = callTimeout, maximumBodyBytes: Int = maximumBodyBytes
    ) async throws -> ClientResponse {
        try await withThrowingTaskGroup(of: ClientResponse.self) { group in
            group.addTask { try await exchange(request, on: client, maximumBodyBytes: maximumBodyBytes) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            return first
        }
    }

    private static func exchange(
        _ request: ClientRequest, on client: HTTPClient, maximumBodyBytes: Int
    ) async throws -> ClientResponse {
        var outbound = HTTPClientRequest(url: request.url.string)
        outbound.method = request.method
        outbound.headers = request.headers
        if let body = request.body { outbound.body = .bytes(body) }

        // No deadline of its own: the task group in `send` bounds the whole
        // call, and cancelling this task cancels the request.
        let response = try await client.execute(outbound, deadline: .distantFuture)
        let body: ByteBuffer
        do {
            body = try await response.body.collect(upTo: maximumBodyBytes)
        } catch is NIOTooManyBytesError {
            throw Failure.responseTooLarge
        }
        return ClientResponse(
            status: response.status, headers: response.headers,
            body: body.readableBytes > 0 ? body : nil)
    }
}
