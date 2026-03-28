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
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        let config = AppSecurityConfiguration(
            publicBaseURL: publicBaseURL.flatMap { URL(string: $0) },
            enforceHTTPS: enforceHTTPS,
            trustForwardedProto: trustForwardedProto,
            sessionCookieSecure: false
        )
        app.middleware.use(HTTPSRedirectMiddleware(configuration: config))
        app.get("test") { _ in "ok" }
        app.post("submit") { _ in "submitted" }
        app.post("api", "v1", "worker", "request") { _ in "worker-ok" }
        return app
    }

    // MARK: - Enforcement disabled

    func testNoRedirectWhenEnforcementDisabled() async throws {
        try await withApp(try await makeApp(enforceHTTPS: false)) { app in
            try await app.testable().test(.GET, "/test") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, "ok")
            }
        }
    }

    // MARK: - HTTPS pass-through

    func testHTTPSRequestPassesThrough() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/test", beforeRequest: { req async in
                req.headers.add(name: "X-Forwarded-Proto", value: "https")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            })
        }
    }

    // MARK: - GET redirect

    func testGETRedirectsToHTTPS() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/test", beforeRequest: { req async in
                req.headers.add(name: .host, value: "example.com")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .temporaryRedirect)
                let location = res.headers.first(name: .location) ?? ""
                XCTAssertTrue(location.hasPrefix("https://"), "Expected https redirect, got: \(location)")
                XCTAssertTrue(location.contains("example.com"), "Expected host in redirect, got: \(location)")
                XCTAssertTrue(location.contains("/test"), "Expected path in redirect, got: \(location)")
            })
        }
    }

    // MARK: - POST returns 426

    func testPOSTReturns426() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, "/submit", beforeRequest: { req async in
                req.headers.add(name: .host, value: "example.com")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .upgradeRequired)
            })
        }
    }

    func testWorkerPOSTBypassesHTTPSEnforcement() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, "/api/v1/worker/request", beforeRequest: { req async in
                req.headers.add(name: .host, value: "server:8080")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, "worker-ok")
            })
        }
    }

    // MARK: - X-Forwarded-Proto trust

    func testForwardedProtoHTTPSPassesThrough() async throws {
        try await withApp(try await makeApp(trustForwardedProto: true)) { app in
            try await app.testable().test(.GET, "/test", beforeRequest: { req async in
                req.headers.add(name: "X-Forwarded-Proto", value: "https")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            })
        }
    }

    func testForwardedProtoHTTPRedirects() async throws {
        try await withApp(try await makeApp(trustForwardedProto: true)) { app in
            try await app.testable().test(.GET, "/test", beforeRequest: { req async in
                req.headers.add(name: "X-Forwarded-Proto", value: "http")
                req.headers.add(name: .host, value: "example.com")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .temporaryRedirect)
            })
        }
    }

    // MARK: - X-Forwarded-Host in redirect

    func testRedirectUsesForwardedHost() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/test", beforeRequest: { req async in
                req.headers.add(name: "X-Forwarded-Host", value: "public.example.com")
                req.headers.add(name: .host, value: "internal.local")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .temporaryRedirect)
                let location = res.headers.first(name: .location) ?? ""
                XCTAssertTrue(location.contains("public.example.com"),
                    "Expected forwarded host in redirect, got: \(location)")
            })
        }
    }

    // MARK: - publicBaseURL override

    func testRedirectUsesPublicBaseURL() async throws {
        try await withApp(try await makeApp(publicBaseURL: "https://chickadee.example.edu")) { app in
            try await app.testable().test(.GET, "/test", beforeRequest: { req async in
                req.headers.add(name: .host, value: "internal.local")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .temporaryRedirect)
                let location = res.headers.first(name: .location) ?? ""
                XCTAssertTrue(location.hasPrefix("https://chickadee.example.edu/test"),
                    "Expected publicBaseURL in redirect, got: \(location)")
            })
        }
    }

    // MARK: - Fallback host

    func testRedirectFallsBackToLocalhost() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/test", afterResponse: { res async in
                XCTAssertEqual(res.status, .temporaryRedirect)
                let location = res.headers.first(name: .location) ?? ""
                XCTAssertTrue(location.contains("localhost"),
                    "Expected localhost fallback, got: \(location)")
            })
        }
    }

    // MARK: - HEAD treated same as GET

    func testHEADRedirectsLikeGET() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.HEAD, "/test", beforeRequest: { req async in
                req.headers.add(name: .host, value: "example.com")
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .temporaryRedirect)
            })
        }
    }
}
