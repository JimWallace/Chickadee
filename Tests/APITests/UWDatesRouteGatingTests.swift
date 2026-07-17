// Tests/APITests/UWDatesRouteGatingTests.swift
//
// The UW important-dates endpoint is an optional institutional integration
// (#278): registered by default, absent entirely when
// UW_IMPORTANT_DATES_ENABLED=false. These tests pin the mount behaviour
// without touching the network — an unauthenticated /api/ request stops at
// ActiveCourseStaffMiddleware (401) when the route exists, and 404s when it
// was never registered.

import Fluent
import Testing
import VaporTesting

@testable import APIServer

@Suite struct UWDatesRouteGatingTests {

    @Test func routeIsRegisteredByDefault() async throws {
        try await withApp(try await makeTestApp(prefix: "chickadee-uwdates")) { app in
            try await app.testing().test(.GET, "/api/v1/uw-dates") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func routeIsAbsentWhenDisabled() async throws {
        let config = AppConfig.testDefaults(uwDates: UWDatesConfig(enabled: false))
        let app = try await makeTestApp(prefix: "chickadee-uwdates", appConfig: config)
        try await withApp(app) { app in
            try await app.testing().test(.GET, "/api/v1/uw-dates") { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
