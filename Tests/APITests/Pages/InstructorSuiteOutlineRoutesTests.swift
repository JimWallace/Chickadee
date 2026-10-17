// Tests/APITests/Pages/InstructorSuiteOutlineRoutesTests.swift
//
// GET /instructor/:assignmentID/suite-outline.json end to end (notebook views
// NB6): course staff get the outline, which names hidden tests; a student
// gets nothing.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorSuiteOutlineRoutesTests {

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","requiredFiles":[],\
        "sections":[{"id":"s1","name":"Task 1: Warm up"}],\
        "testSuites":[{"tier":"public","script":"test_a.py","sectionID":"s1"},\
        {"tier":"secret","script":"secret_b.py","sectionID":"s1","points":2}],"timeLimitSeconds":10}
        """

    @Test func staffGetTheOutline() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await arInsertSetup(id: "setup_outline", manifest: manifest, on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_outline", title: "Outline Lab", isOpen: false,
                validationStatus: "passed", on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/suite-outline.json",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .cacheControl) == "private, no-store")
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let outline = try decoder.decode(InstructorSuiteOutline.self, from: Data(res.body.string.utf8))
                    #expect(outline.validation.status == "passed")
                    #expect(outline.totals == .init(checks: 2, points: 3))
                    // No notebook names anything: both items link to no cell.
                    #expect(outline.unlinked.map(\.id) == ["test_a.py", "secret_b.py"])
                    #expect(outline.unlinked.map(\.tier) == ["public", "secret"])
                })
        }
    }

    @Test func aStudentGetsNothing() async throws {
        try await withAssignmentRoutesApp { app in
            try await arInsertSetup(id: "setup_outline_s", manifest: manifest, on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "setup_outline_s", title: "Outline Lab", isOpen: true, on: app)
            let cookie = try await arLoginAsStudent(on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/suite-outline.json",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status != .ok)
                    #expect(!res.body.string.contains("secret_b"))
                })
        }
    }
}
