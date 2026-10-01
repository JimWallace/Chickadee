// Tests/APITests/BrightSpaceCourseBindingTests.swift
//
// Binding a course to its LEARN org unit without a request: clearing leaves
// the sync identity alone, binding needs a connected binder and makes them
// the sync identity, and with no client resolvable the binding is saved
// unverified. Verification and auto-mapping need D2L, so they are covered
// by the route tests and the transport tests.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class BrightSpaceCourseBindingTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp()
    }

    @Test func clearingLeavesTheSyncIdentityAlone() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "BB1")
            let designated = UUID()
            course.brightspaceOrgUnitID = "12345"
            course.brightspaceOrgUnitName = "CS 135"
            course.brightspaceSyncUserID = designated
            try await course.save(on: app.db)

            try await BrightSpaceCourseBinding.clearOrgUnit(course: course, on: app.db)

            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceOrgUnitID == nil)
            #expect(reloaded.brightspaceOrgUnitName == nil)
            #expect(reloaded.brightspaceSyncUserID == designated)
        }
    }

    @Test func bindingNeedsAConnectedBinder() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "BB2")
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let binder = try instructor.requireID()

            await #expect(throws: BrightSpaceCourseBinding.BindError.binderNotConnected) {
                _ = try await BrightSpaceCourseBinding.bindOrgUnit(
                    course: course, orgUnitID: "12345", binderUUID: binder, on: app.db, application: app)
            }
            #expect(course.brightspaceOrgUnitID == nil)
        }
    }

    @Test func bindingMakesTheBinderTheSyncIdentityAndSavesUnverifiedWithoutAClient() async throws {
        try await withApp(app) { app in
            // No app credentials: a key is stored, but no client can resolve,
            // so the binding is saved and reported unverified.
            app.brightSpaceAppCredentials = nil
            let course = try await makeTestCourse(on: app, code: "BB3")
            let instructor = try await makeTestUser(on: app, username: "plee", role: "instructor")
            let binder = try instructor.requireID()
            try await BrightSpaceCredentialStore.save(
                valenceUserID: "u", valenceUserKey: "k", identityName: "Prof Lee",
                capturedByUserID: binder, userID: binder, on: app.db)

            let verification = try await BrightSpaceCourseBinding.bindOrgUnit(
                course: course, orgUnitID: "12345", binderUUID: binder, on: app.db, application: app)

            #expect(verification == .unverified)
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceOrgUnitID == "12345")
            #expect(reloaded.brightspaceOrgUnitName == nil)
            #expect(reloaded.brightspaceSyncUserID == binder)
        }
    }
}
