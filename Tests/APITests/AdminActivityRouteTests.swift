// Tests/APITests/AdminActivityRouteTests.swift
//
// Coverage for GET /admin/activity (the activity-chart JSON endpoint) and the
// activity section rendered onto the admin overview page.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminActivityRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-adminactivity")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "activity_admin", password: "testpassword", role: "admin", on: app)
    }

    @Test func activityEndpoint_returnsRequestedWindow() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin/activity?window=1w",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.add(name: "X-Background-Refresh", value: "1")
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let data = try res.content.decode(ActivityChartData.self)
                    #expect(data.window == "1w")
                    #expect(data.buckets.count == 7)
                })
        }
    }

    @Test func activityEndpoint_defaultsTo24hOnBadWindow() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin/activity?window=bogus",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let data = try res.content.decode(ActivityChartData.self)
                    #expect(data.window == "24h")
                    #expect(data.buckets.count == 24)
                })
        }
    }

    @Test func activityEndpoint_requiresAdmin() async throws {
        try await withApp(app) { _ in
            let studentCookie = try await loginUser(
                username: "activity_student", password: "testpassword", role: "student", on: app)
            try await app.asyncTest(
                .GET, "/admin/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: studentCookie)
                },
                afterResponse: { res in
                    #expect(res.status != .ok, "Non-admins must not reach /admin/activity")
                })
        }
    }

    @Test func overviewPageRendersActivitySection() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("Active Users"))
                    #expect(body.contains("activity-bars"))
                    #expect(body.contains("data-window=\"1m\""))
                })
        }
    }
}
