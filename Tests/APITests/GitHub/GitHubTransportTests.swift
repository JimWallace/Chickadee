// Tests/APITests/GitHub/GitHubTransportTests.swift
//
// Every GitHub seam sends through `GitHubTransport` (#1769): GitHub's headers on
// each call, and a reachability record for each one. Before it, only the
// repository client recorded reachability, so a GitHub outage during account
// linking or course binding never reached the egress rule. Vapor's client is
// replaced with a recording one, so nothing here reaches the network.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// Records every request and answers each with one canned response, or fails
/// the send as an unreachable host would.
private final class RecordingGitHubClient: Client, Sendable {
    struct Sent: Sendable {
        let method: HTTPMethod
        let url: String
        let headers: HTTPHeaders
    }

    struct Answer: Sendable {
        var status: HTTPResponseStatus = .ok
        var body: String?
        var fails = false
    }

    struct Unreachable: Error {}

    let eventLoop: EventLoop
    let sent: NIOLockedValueBox<[Sent]>
    let answer: Answer

    init(eventLoop: EventLoop, sent: NIOLockedValueBox<[Sent]>, answer: Answer) {
        self.eventLoop = eventLoop
        self.sent = sent
        self.answer = answer
    }

    func delegating(to eventLoop: EventLoop) -> Client {
        RecordingGitHubClient(eventLoop: eventLoop, sent: sent, answer: answer)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        sent.withLockedValue {
            $0.append(Sent(method: request.method, url: request.url.string, headers: request.headers))
        }
        if answer.fails { return eventLoop.makeFailedFuture(Unreachable()) }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: answer.status, headers: headers, body: answer.body.map { ByteBuffer(string: $0) }))
    }
}

@Suite(.serialized) final class GitHubTransportTests {

    let app: Application
    fileprivate let sent = NIOLockedValueBox<[RecordingGitHubClient.Sent]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-transport")
    }

    private func answer(_ answer: RecordingGitHubClient.Answer) {
        let box = sent
        app.clients.use { app in
            RecordingGitHubClient(eventLoop: app.eventLoopGroup.next(), sent: box, answer: answer)
        }
    }

    @Test func everySeamSendsGitHubsHeadersAndRecordsReachability() async throws {
        try await withApp(app) { app in
            answer(.init(body: #"{"id": 7, "login": "octo"}"#))
            let oauth = GitHubOAuthClient.live(app: app)
            #expect(try await oauth.fetchUser("user-token") == GitHubUser(id: 7, login: "octo"))
            #expect(try await GitHubRepoClient.live(app: app).userLogin("installation-token", 7) == "octo")
            // The answer is not a conversion, so the decode throws; GitHub was
            // still reached, and that is what is recorded.
            _ = try? await app.githubManifestConverter("code123")
            answer(.init(status: .noContent))
            try await oauth.revokeToken("user-token", "Iv1.client", "client-secret")

            let requests = sent.withLockedValue { $0 }
            #expect(
                requests.map(\.url) == [
                    "https://api.github.com/user", "https://api.github.com/user/7",
                    "https://api.github.com/app-manifests/code123/conversions",
                    "https://api.github.com/applications/Iv1.client/token",
                ])
            for request in requests {
                #expect(request.headers.first(name: .userAgent) == "Chickadee")
                #expect(request.headers.first(name: "X-GitHub-Api-Version") == "2022-11-28")
                #expect(request.headers.first(name: .accept) == "application/vnd.github+json")
            }
            let snapshot = await app.outboundReachability.snapshot(window: 3600)
            #expect(snapshot.successesInWindow == 4)
            #expect(snapshot.failuresInWindow == 0)
        }
    }

    /// The account-linking and App-registration calls used to record nothing,
    /// so an outage there was invisible. Now each failed send is a GitHub
    /// failure.
    @Test func aFailedSendIsRecordedAsAGitHubOutage() async throws {
        try await withApp(app) { app in
            answer(.init(fails: true))
            let exchange = GitHubCodeExchange(
                clientID: "Iv1.client", clientSecret: "secret", code: "code", codeVerifier: "verifier",
                redirectURI: "https://courses.example.edu/github/callback")
            _ = try? await GitHubOAuthClient.live(app: app).exchangeCode(exchange)
            _ = try? await GitHubOAuthClient.live(app: app).userInstallations("user-token")
            _ = try? await app.githubManifestConverter("code123")

            let snapshot = await app.outboundReachability.snapshot(window: 3600)
            #expect(snapshot.failuresInWindow == 3)
            #expect(snapshot.destinationsFailing == ["GitHub"])
            // The token exchange goes to github.com with its own headers.
            let exchangeRequest = try #require(sent.withLockedValue { $0 }.first)
            #expect(exchangeRequest.url == "https://github.com/login/oauth/access_token")
            #expect(exchangeRequest.headers.first(name: .accept) == "application/json")
            #expect(exchangeRequest.headers.first(name: .userAgent) == "Chickadee")
        }
    }
}
