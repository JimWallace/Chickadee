// Tests for MCPResourceProvider — the backing for resources/list and
// resources/read. Backed by a real test database. Verifies course-scoping
// (listing confined to accessible courses; reads denied for inaccessible
// assignments), admin breadth, and URI parsing.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPResourcesTests {
    private func context(
        _ app: Application, subject: String, scopes: Set<ContentScope> = [.read]
    ) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: scopes)
    }

    private let sampleManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}"#

    // MARK: - resources/list

    @Test func listReturnsManifestsOnlyForAccessibleCourses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseA = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let courseB = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(
                on: app, userID: prof.requireID(), courseID: courseA.requireID())
            try await makeTestSetup(
                on: app, id: "setup_a", courseID: courseA.requireID(), manifest: sampleManifest)
            try await makeTestSetup(on: app, id: "setup_b", courseID: courseB.requireID())
            let a = try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: courseA.requireID(), title: "Lab A")
            let b = try await makeTestAssignment(
                on: app, testSetupID: "setup_b", courseID: courseB.requireID(), title: "Lab B")

            let result = try await MCPResourceProvider().list(context: context(app, subject: "prof"))
            let uris = Self.resourceURIs(result)
            #expect(uris.contains(MCPResourceProvider.manifestURI(publicID: a.publicID)))
            #expect(!uris.contains(MCPResourceProvider.manifestURI(publicID: b.publicID)))
        }
    }

    @Test func listForAdminIncludesEveryCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseA = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let courseB = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            _ = try await makeTestUser(on: app, username: "boss", role: "admin")
            try await makeTestSetup(on: app, id: "setup_a", courseID: courseA.requireID())
            try await makeTestSetup(on: app, id: "setup_b", courseID: courseB.requireID())
            let a = try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: courseA.requireID(), title: "Lab A")
            let b = try await makeTestAssignment(
                on: app, testSetupID: "setup_b", courseID: courseB.requireID(), title: "Lab B")

            let result = try await MCPResourceProvider().list(context: context(app, subject: "boss"))
            let uris = Self.resourceURIs(result)
            #expect(uris.contains(MCPResourceProvider.manifestURI(publicID: a.publicID)))
            #expect(uris.contains(MCPResourceProvider.manifestURI(publicID: b.publicID)))
        }
    }

    @Test func listRejectsStudentSubject() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let student = try await makeTestUser(on: app, username: "stu", role: "student")
            try await makeTestEnrollment(
                on: app, userID: student.requireID(), courseID: course.requireID())
            await #expect(throws: MCPToolError.self) {
                _ = try await MCPResourceProvider().list(context: context(app, subject: "stu"))
            }
        }
    }

    // MARK: - resources/read

    @Test func readReturnsManifestJSON() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(
                on: app, userID: prof.requireID(), courseID: course.requireID())
            try await makeTestSetup(
                on: app, id: "setup_a", courseID: course.requireID(), manifest: sampleManifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_a", courseID: course.requireID(), title: "Lab A")

            let uri = MCPResourceProvider.manifestURI(publicID: assignment.publicID)
            let result = try await MCPResourceProvider().read(
                uri: uri, context: context(app, subject: "prof"))
            #expect(Self.firstContentText(result) == sampleManifest)
        }
    }

    @Test func readDeniesInaccessibleAssignment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseA = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let courseB = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            // Enrolled in A only.
            try await makeTestEnrollment(
                on: app, userID: prof.requireID(), courseID: courseA.requireID())
            try await makeTestSetup(on: app, id: "setup_b", courseID: courseB.requireID())
            let b = try await makeTestAssignment(
                on: app, testSetupID: "setup_b", courseID: courseB.requireID(), title: "Lab B")

            let uri = MCPResourceProvider.manifestURI(publicID: b.publicID)
            await #expect(throws: MCPToolError.self) {
                _ = try await MCPResourceProvider().read(
                    uri: uri, context: context(app, subject: "prof"))
            }
        }
    }

    @Test func readRejectsMalformedURI() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Intro")
            let prof = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(
                on: app, userID: prof.requireID(), courseID: course.requireID())
            for uri in ["chickadee://assignment/zzzzzz/manifest", "not-a-uri", "chickadee://assignment//manifest"] {
                await #expect(throws: MCPToolError.self) {
                    _ = try await MCPResourceProvider().read(
                        uri: uri, context: context(app, subject: "prof"))
                }
            }
        }
    }

    // MARK: - URI round-trip

    @Test func manifestURIRoundTrips() {
        #expect(
            MCPResourceProvider.manifestPublicID(fromURI: MCPResourceProvider.manifestURI(publicID: "abc123"))
                == "abc123")
        #expect(MCPResourceProvider.manifestPublicID(fromURI: "chickadee://assignment//manifest") == nil)
        #expect(MCPResourceProvider.manifestPublicID(fromURI: "chickadee://assignment/a/b/manifest") == nil)
        #expect(MCPResourceProvider.manifestPublicID(fromURI: "http://evil/manifest") == nil)
    }

    // MARK: - Helpers

    private static func resourceURIs(_ value: JSONValue) -> [String] {
        guard case .object(let root) = value, case .array(let items)? = root["resources"] else {
            return []
        }
        return items.compactMap { item in
            guard case .object(let fields) = item, case .string(let uri)? = fields["uri"] else {
                return nil
            }
            return uri
        }
    }

    private static func firstContentText(_ value: JSONValue) -> String? {
        guard case .object(let root) = value, case .array(let contents)? = root["contents"],
            let first = contents.first, case .object(let fields) = first,
            case .string(let text)? = fields["text"]
        else { return nil }
        return text
    }
}
