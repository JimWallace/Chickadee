// Tests/APITests/HTTPSRedirectMiddlewareTests.swift
//
// Unit tests for HTTPSRedirectMiddleware — redirect logic, proxy header trust,
// GET vs POST handling, and publicBaseURL override.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct HTTPSRedirectMiddlewareTests {

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
            sessionCookieSecure: false,
            sessionIdleTimeoutSeconds: 0
        )
        app.middleware.use(HTTPSRedirectMiddleware(configuration: config))
        app.get("test") { _ in "ok" }
        app.post("submit") { _ in "submitted" }
        // Internal endpoints that must stay reachable over plain HTTP.
        app.post("api", "v1", "worker", "request") { _ in "polled" }
        app.get("health") { _ in "healthy" }
        return app
    }

    // MARK: - Enforcement disabled

    @Test func noRedirectWhenEnforcementDisabled() async throws {
        try await withApp(try await makeApp(enforceHTTPS: false)) { app in
            try await app.testable().test(.GET, "/test") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            }
        }
    }

    // MARK: - HTTPS pass-through

    @Test func httpsRequestPassesThrough() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                })
        }
    }

    // MARK: - GET redirect

    @Test func getRedirectsToHTTPS() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: .host, value: "example.com")
                },
                afterResponse: { res async in
                    #expect(res.status == .temporaryRedirect)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(location.hasPrefix("https://"), "Expected https redirect, got: \(location)")
                    #expect(location.contains("example.com"), "Expected host in redirect, got: \(location)")
                    #expect(location.contains("/test"), "Expected path in redirect, got: \(location)")
                })
        }
    }

    // MARK: - POST returns 426

    @Test func postReturns426() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .POST, "/submit",
                beforeRequest: { req async in
                    req.headers.add(name: .host, value: "example.com")
                },
                afterResponse: { res async in
                    #expect(res.status == .upgradeRequired)
                })
        }
    }

    // MARK: - Internal endpoints exempt from enforcement

    @Test func workerPostPassesThroughOverPlainHTTP() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .POST, "/api/v1/worker/request",
                beforeRequest: { req async in
                    req.headers.add(name: .host, value: "example.com")
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "polled")
                })
        }
    }

    @Test func healthGetPassesThroughOverPlainHTTP() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/health",
                beforeRequest: { req async in
                    req.headers.add(name: .host, value: "example.com")
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "healthy")
                })
        }
    }

    // MARK: - X-Forwarded-Proto trust

    @Test func forwardedProtoHTTPSPassesThrough() async throws {
        try await withApp(try await makeApp(trustForwardedProto: true)) { app in
            try await app.testable().test(
                .GET, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: "X-Forwarded-Proto", value: "https")
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                })
        }
    }

    @Test func forwardedProtoHTTPRedirects() async throws {
        try await withApp(try await makeApp(trustForwardedProto: true)) { app in
            try await app.testable().test(
                .GET, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: "X-Forwarded-Proto", value: "http")
                    req.headers.add(name: .host, value: "example.com")
                },
                afterResponse: { res async in
                    #expect(res.status == .temporaryRedirect)
                })
        }
    }

    // MARK: - X-Forwarded-Host in redirect

    @Test func redirectUsesForwardedHost() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: "X-Forwarded-Host", value: "public.example.com")
                    req.headers.add(name: .host, value: "internal.local")
                },
                afterResponse: { res async in
                    #expect(res.status == .temporaryRedirect)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(
                        location.contains("public.example.com"),
                        "Expected forwarded host in redirect, got: \(location)")
                })
        }
    }

    // MARK: - publicBaseURL override

    @Test func redirectUsesPublicBaseURL() async throws {
        try await withApp(try await makeApp(publicBaseURL: "https://chickadee.example.edu")) { app in
            try await app.testable().test(
                .GET, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: .host, value: "internal.local")
                },
                afterResponse: { res async in
                    #expect(res.status == .temporaryRedirect)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(
                        location.hasPrefix("https://chickadee.example.edu/test"),
                        "Expected publicBaseURL in redirect, got: \(location)")
                })
        }
    }

    // MARK: - Fallback host

    @Test func redirectFallsBackToLocalhost() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/test",
                afterResponse: { res async in
                    #expect(res.status == .temporaryRedirect)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(location.contains("localhost"), "Expected localhost fallback, got: \(location)")
                })
        }
    }

    // MARK: - HEAD treated same as GET

    @Test func headRedirectsLikeGET() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .HEAD, "/test",
                beforeRequest: { req async in
                    req.headers.add(name: .host, value: "example.com")
                },
                afterResponse: { res async in
                    #expect(res.status == .temporaryRedirect)
                })
        }
    }
}
