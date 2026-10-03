// Tests/APITests/GitHub/ScriptedGitHubClient.swift
//
// A Vapor `Client` that stands in for GitHub in the live-closure tests
// (#1775). It records each request — method, URL, headers and body — and
// answers from a script keyed by method and URL, so a test drives the real
// request builders and status rules without reaching the network.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

final class ScriptedGitHubClient: Client, Sendable {
    struct Sent: Sendable {
        let method: HTTPMethod
        let url: String
        let headers: HTTPHeaders
        let body: String?
    }

    struct Answer: Sendable {
        var status: HTTPResponseStatus = .ok
        var body: String?
        var headers: [(String, String)] = []

        static func json(_ body: String, status: HTTPResponseStatus = .ok) -> Answer {
            Answer(status: status, body: body)
        }
    }

    /// The script: each request's answer, keyed by `"METHOD url"`. A request
    /// the script does not name is answered 500, so a wrong URL fails loudly.
    typealias Script = [String: Answer]

    let eventLoop: EventLoop
    let sent: NIOLockedValueBox<[Sent]>
    let script: NIOLockedValueBox<Script>

    init(eventLoop: EventLoop, sent: NIOLockedValueBox<[Sent]>, script: NIOLockedValueBox<Script>) {
        self.eventLoop = eventLoop
        self.sent = sent
        self.script = script
    }

    func delegating(to eventLoop: EventLoop) -> Client {
        ScriptedGitHubClient(eventLoop: eventLoop, sent: sent, script: script)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let body = request.body.map { String(buffer: $0) }
        sent.withLockedValue {
            $0.append(Sent(method: request.method, url: request.url.string, headers: request.headers, body: body))
        }
        let key = "\(request.method.rawValue) \(request.url.string)"
        let answer = script.withLockedValue { $0[key] } ?? Answer(status: .internalServerError)
        var headers = HTTPHeaders()
        headers.contentType = .json
        for (name, value) in answer.headers { headers.replaceOrAdd(name: name, value: value) }
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: answer.status, headers: headers, body: answer.body.map { ByteBuffer(string: $0) }))
    }
}

extension Application {
    /// Replaces Vapor's client with a scripted one and returns the boxes the
    /// test reads and writes.
    func useScriptedGitHub() -> (
        sent: NIOLockedValueBox<[ScriptedGitHubClient.Sent]>,
        script: NIOLockedValueBox<ScriptedGitHubClient.Script>
    ) {
        let sent = NIOLockedValueBox<[ScriptedGitHubClient.Sent]>([])
        let script = NIOLockedValueBox<ScriptedGitHubClient.Script>([:])
        clients.use { app in
            ScriptedGitHubClient(eventLoop: app.eventLoopGroup.next(), sent: sent, script: script)
        }
        return (sent, script)
    }
}
