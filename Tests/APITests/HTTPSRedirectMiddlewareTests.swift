// Tests/APITests/HTTPSRedirectMiddlewareTests.swift
//
// Unit tests for HTTPSRedirectMiddleware — redirect logic, proxy header trust,
// GET vs POST handling, and publicBaseURL override.

import XCTest
import XCTVapor
@testable import chickadee_server
import Foundation

final class HTTPSRedirectMiddlewareTests: XCTestCase {

    // MARK: - Helpers

    private func makeApp(
        enforceHTTPS: Bool = true,
        trustForwardedProto: Bool = true,
        publicBaseURL: String? = nil
    ) throws -> Application {
        let app = Application(.testing)
        let config = AppSecurityConfiguration(
            publicBaseURL: publicBaseURL.flatMap { URL(string: $0) },
            enforceHTTPS: enforceHTTPS,
            trustForwardedProto: trustForwardedProto,
            sessionCookieSecure: false
        )
        app.middleware.use(HTTPSRedirectMiddleware(configuration: config))
        app.get("test") { _ in "ok" }
        app.post("submit") { _ in "submitted" }
        return app
    }

    // MARK: - Enforcement disabled

    func testNoRedirectWhenEnforcementDisabled() throws {
        let app = try makeApp(enforceHTTPS: false)
        defer { app.shutdown() }

        try app.test(.GET, "/test") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "ok")
        }
    }

    // MARK: - HTTPS pass-through

    func testHTTPSRequestPassesThrough() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.GET, "/test", beforeRequest: { req in
            req.headers.add(name: "X-Forwarded-Proto", value: "https")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    // MARK: - GET redirect

    func testGETRedirectsToHTTPS() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.GET, "/test", beforeRequest: { req in
            req.headers.add(name: .host, value: "example.com")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .temporaryRedirect)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.hasPrefix("https://"), "Expected https redirect, got: \(location)")
            XCTAssertTrue(location.contains("example.com"), "Expected host in redirect, got: \(location)")
            XCTAssertTrue(location.contains("/test"), "Expected path in redirect, got: \(location)")
        })
    }

    // MARK: - POST returns 426

    func testPOSTReturns426() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.POST, "/submit", beforeRequest: { req in
            req.headers.add(name: .host, value: "example.com")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .upgradeRequired)
        })
    }

    // MARK: - X-Forwarded-Proto trust

    func testForwardedProtoHTTPSPassesThrough() throws {
        let app = try makeApp(trustForwardedProto: true)
        defer { app.shutdown() }

        try app.test(.GET, "/test", beforeRequest: { req in
            req.headers.add(name: "X-Forwarded-Proto", value: "https")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testForwardedProtoHTTPRedirects() throws {
        let app = try makeApp(trustForwardedProto: true)
        defer { app.shutdown() }

        try app.test(.GET, "/test", beforeRequest: { req in
            req.headers.add(name: "X-Forwarded-Proto", value: "http")
            req.headers.add(name: .host, value: "example.com")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .temporaryRedirect)
        })
    }

    // MARK: - X-Forwarded-Host in redirect

    func testRedirectUsesForwardedHost() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.GET, "/test", beforeRequest: { req in
            req.headers.add(name: "X-Forwarded-Host", value: "public.example.com")
            req.headers.add(name: .host, value: "internal.local")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .temporaryRedirect)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("public.example.com"),
                "Expected forwarded host in redirect, got: \(location)")
        })
    }

    // MARK: - publicBaseURL override

    func testRedirectUsesPublicBaseURL() throws {
        let app = try makeApp(publicBaseURL: "https://chickadee.example.edu")
        defer { app.shutdown() }

        try app.test(.GET, "/test", beforeRequest: { req in
            req.headers.add(name: .host, value: "internal.local")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .temporaryRedirect)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.hasPrefix("https://chickadee.example.edu/test"),
                "Expected publicBaseURL in redirect, got: \(location)")
        })
    }

    // MARK: - Fallback host

    func testRedirectFallsBackToLocalhost() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        // No Host, no X-Forwarded-Host
        try app.test(.GET, "/test", afterResponse: { res in
            XCTAssertEqual(res.status, .temporaryRedirect)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("localhost"),
                "Expected localhost fallback, got: \(location)")
        })
    }

    // MARK: - HEAD treated same as GET

    func testHEADRedirectsLikeGET() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.HEAD, "/test", beforeRequest: { req in
            req.headers.add(name: .host, value: "example.com")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .temporaryRedirect)
        })
    }
}
