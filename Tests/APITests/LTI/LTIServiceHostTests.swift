// Tests/APITests/LTI/LTIServiceHostTests.swift
//
// The service calls reach only the hosts an admin registered for the
// platform (docs/compliance/lti-audit-2026-10.md L-1): a line item, a score
// or a membership page on another host is refused before Chickadee sends the
// platform's bearer token to it.

import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct LTIServiceHostTests {
    static let hosts: Set<String> = ["lms.example.edu"]

    private static func toolKey() async throws -> (LTIToolKeyAuthority, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys = try await LTIToolKeyAuthority.loadOrGenerate(path: directory.appendingPathComponent("key").path)
        return (keys, directory)
    }

    // MARK: - The rule

    @Test(arguments: [
        ("https://lms.example.edu/api/lti/courses/7/line_items", true),
        ("https://LMS.Example.EDU/items/1", true),
        ("https://evil.example/items/1", false),
        ("https://lms.example.edu.evil.example/items/1", false),
        ("http://lms.example.edu/items/1", false),
        ("ftp://lms.example.edu/items/1", false),
        ("/items/1", false),
        ("not a url", false),
    ])
    func aURLMustBeSecureAndOnARegisteredHost(url: String, permitted: Bool) {
        #expect(LTIServiceHost.permits(url, hosts: Self.hosts) == permitted)
    }

    @Test func plainHTTPIsAcceptedOnlyOnARegisteredLoopbackHost() {
        #expect(LTIServiceHost.permits("http://localhost:8080/items", hosts: ["localhost"]))
        #expect(!LTIServiceHost.permits("http://localhost:8080/items", hosts: Self.hosts))
        #expect(!LTIServiceHost.permits("http://127.0.0.1/items", hosts: Self.hosts))
    }

    /// Brightspace serves AGS and NRPS from the LMS host and its token
    /// endpoint from another, so both must count.
    @Test func aRegistrationNamesTheHostsOfAllItsURLs() {
        let platform = APILTIPlatform(
            issuer: "https://learn.example.edu", clientID: "client", deploymentIDs: ["d"],
            authLoginURL: "https://learn.example.edu/d2l/lti/authenticate",
            accessTokenURL: "https://auth.example.edu/core/connect/token",
            jwksURL: "https://keys.example.edu/d2l/.well-known/jwks", displayName: "LEARN")
        #expect(platform.registeredHosts == ["learn.example.edu", "auth.example.edu", "keys.example.edu"])
        let target = LTIServiceClient.Platform(id: UUID(), registration: platform)
        #expect(target.serviceHosts == platform.registeredHosts)
    }

    @Test func aServicePlatformAlwaysReachesItsTokenHost() {
        let target = LTIServiceClient.Platform(
            id: UUID(), clientID: "client", accessTokenURL: "https://auth.example.edu/token")
        #expect(target.serviceHosts == ["auth.example.edu"])
    }

    @Test func theRefusalIsTerminalAndShort() {
        let error = LTIServiceError.foreignHost(.createLineItem)
        #expect(!error.isRetryable)
        #expect(error.description.split(separator: " ").count <= 15)
    }

    // MARK: - The client

    @Test func aLineItemOnAnotherHostIsNotScored() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()
        await lms.addExistingLineItem(resourceID: "abc123", url: "https://evil.example/items/2")
        let platform = LTIServiceClient.Platform(
            id: UUID(), clientID: "chickadee-client", accessTokenURL: LTITestGradeService.tokenURL)
        let client = await lms.client

        let url = try await client.lineItemURL(
            resourceID: "abc123", label: "Lab 1", scoreMaximum: 10,
            lineItemsURL: LTITestGradeService.lineItemsURL, platform: platform, keys: keys)
        await #expect(throws: LTIServiceError.foreignHost(.postScore)) {
            try await client.postScore(
                .graded(userID: "subject-1", points: 7, maximum: 10, at: Date()),
                lineItemURL: url, platform: platform, keys: keys)
        }
        #expect(await lms.requests.allSatisfy { !$0.url.contains("evil.example") })
    }

    @Test func aLineItemsURLOnAnotherHostIsNotCalled() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lms = LTITestGradeService()
        let platform = LTIServiceClient.Platform(
            id: UUID(), clientID: "chickadee-client", accessTokenURL: LTITestGradeService.tokenURL)

        await #expect(throws: LTIServiceError.foreignHost(.findLineItem)) {
            _ = try await lms.client.lineItemURL(
                resourceID: "abc123", label: "Lab 1", scoreMaximum: 10,
                lineItemsURL: "https://evil.example/line_items", platform: platform, keys: keys)
        }
        #expect(await lms.requests.allSatisfy { !$0.url.contains("evil.example") })
    }

    @Test func aMembershipPageLinkToAnotherHostIsNotFollowed() async throws {
        let (keys, directory) = try await Self.toolKey()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sent = SentURLs()
        let client = LTIServiceClient { request in
            await sent.append(request.url.string)
            let json = HTTPHeaders([("Content-Type", "application/json")])
            if request.url.string == LTITestGradeService.tokenURL {
                return ClientResponse(
                    status: .ok, headers: json,
                    body: ByteBuffer(string: #"{"access_token":"t","token_type":"Bearer","expires_in":3600}"#))
            }
            var headers = json
            headers.add(name: .link, value: #"<https://evil.example/members?page=2>; rel="next""#)
            return ClientResponse(status: .ok, headers: headers, body: ByteBuffer(string: #"{"members":[]}"#))
        }
        let platform = LTIServiceClient.Platform(
            id: UUID(), clientID: "chickadee-client", accessTokenURL: LTITestGradeService.tokenURL)

        await #expect(throws: LTIServiceError.foreignHost(.memberships)) {
            _ = try await client.members(
                membershipsURL: LTITestGradeService.membershipsURL, platform: platform, keys: keys)
        }
        #expect(await sent.urls == [LTITestGradeService.tokenURL, LTITestGradeService.membershipsURL])
    }
}

/// The URLs a stand-in LMS was asked for, in order.
private actor SentURLs {
    private(set) var urls: [String] = []

    func append(_ url: String) {
        urls.append(url)
    }
}
