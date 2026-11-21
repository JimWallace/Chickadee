// Tests/APITests/BrightSpace/ScriptedLearnTab.swift
//
// Shared set-up for the tests that drive the instructor LEARN routes against
// a scripted D2L: `BrightSpaceTabActionTests` and `LearnRosterCheckRouteTests`.
// The app has BrightSpace app credentials, `app.client` is a
// `ScriptedValenceClient`, and the shared TEST101 course is bound to an org
// unit. The signed-in instructor can be its connected sync identity. No
// request reaches the network.

import Core
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A script that answers each request with the reply whose key is a fragment
/// of the request URL. The version discovery gets a 404, so the fallback API
/// versions apply, and so does a request that no key names. Keep the keys
/// apart: no URL may contain two of them.
func scriptedLearn(_ replies: [String: ScriptedValenceReply]) -> ScriptedValenceClient.Script {
    { _, url, _ in
        if url.contains("/versions/") { return ScriptedValenceReply(.notFound) }
        for (fragment, reply) in replies where url.contains(fragment) {
            return reply
        }
        return ScriptedValenceReply(.notFound)
    }
}

/// The instructor session that a test drives the LEARN routes with.
struct ScriptedLearnTab {
    let cookie: String
    let csrf: String
    let courseID: UUID
    let instructorID: UUID
    let sent: NIOLockedValueBox<[ScriptedValenceRequest]>

    /// The URLs of every request to D2L except the version discovery.
    var calls: [String] {
        sent.withLockedValue { $0 }.map(\.url).filter { !$0.contains("/versions/") }
    }
}

/// Configures BrightSpace on `app`, routes `app.client` to `script`, signs
/// in the test instructor of the shared TEST101 course, and binds that course
/// to `orgUnitID`. When `connected` is true, the instructor has a stored
/// LEARN key and is the course's sync identity, so the course resolves a
/// client.
func openScriptedLearnTab(
    _ app: Application,
    orgUnitID: String? = "900",
    connected: Bool = true,
    script: @escaping ScriptedValenceClient.Script
) async throws -> ScriptedLearnTab {
    app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.example", appID: "test-app-id", appKey: "test-app-key", debounceSecs: 90)
    let sent = app.useScriptedValence(script)
    let courseID = try await app.testCourseID(enrollmentMode: .auto)
    let cookie = try await arLoginAsInstructor(on: app)
    let instructor = try #require(
        try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
    let instructorID = try instructor.requireID()
    let course = try #require(try await APICourse.find(courseID, on: app.db))
    course.brightspaceOrgUnitID = orgUnitID
    if connected {
        try await BrightSpaceCredentialStore.save(
            valenceUserID: "vu", valenceUserKey: "vk", identityName: "Test Instructor",
            capturedByUserID: instructorID, userID: instructorID, on: app.db)
        course.brightspaceSyncUserID = instructorID
    }
    try await course.save(on: app.db)
    let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
    return ScriptedLearnTab(
        cookie: sessionCookie, csrf: csrf, courseID: courseID, instructorID: instructorID, sent: sent)
}

extension ScriptedLearnTab {
    /// POSTs `fields` as a form to `path` in this session, with the CSRF
    /// token.
    func post(_ path: String, _ fields: [String: String] = [:], on app: Application) async throws -> TestResponse {
        try await app.asyncSendRequest(.POST, path) { req in
            req.headers.add(name: .cookie, value: cookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
            var form = fields
            form["_csrf"] = csrf
            try req.content.encode(form, as: .urlEncodedForm)
        }
    }

    /// GETs `path` in this session.
    func get(_ path: String, on app: Application) async throws -> TestResponse {
        try await getResponse(path, cookie: cookie, on: app)
    }

    /// The BrightSpace tab as it renders next, with the flash that the last
    /// action set.
    func page(on app: Application) async throws -> String {
        try await getHTML("/instructor/brightspace", cookie: cookie, on: app)
    }
}
