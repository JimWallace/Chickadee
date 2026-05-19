// Tests/APITests/AssignmentRoutesLifecycleTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AssignmentRoutesLifecycleTests {

    // MARK: - POST /instructor/:id/open

    @Test func openAssignmentSetsIsOpenTrue() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_open", on: app)
            let a = try await arInsertAssignment(testSetupID: "setup_open", title: "Draft", isOpen: false, on: app)
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/open",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor")
                })

            let updated = try await APIAssignment.find(a.id, on: app.db)
            #expect(updated?.isOpen == true)

        }
    }

    // MARK: - POST /instructor/:id/close

    @Test func closeAssignmentSetsIsOpenFalse() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_close", on: app)
            let a = try await arInsertAssignment(testSetupID: "setup_close", title: "Open", isOpen: true, on: app)
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/close",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APIAssignment.find(a.id, on: app.db)
            #expect(updated?.isOpen == false)

        }
    }

    // MARK: - POST /instructor/:id/delete

    @Test func deleteAssignmentRemovesRecord() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_del", on: app)
            let a = try await arInsertAssignment(testSetupID: "setup_del", title: "To Remove", isOpen: false, on: app)
            let id = a.publicID

            try await app.asyncTest(
                .POST, "/instructor/\(id)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let gone = try await APIAssignment.find(a.id, on: app.db)
            #expect(gone == nil)

        }
    }

    @Test func deleteNonexistentAssignmentReturnsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            let fakeID = "zzzzzz"

            try await app.asyncTest(
                .POST, "/instructor/\(fakeID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - POST /instructor/:id/open — nonexistent

    @Test func openNonexistentAssignmentReturnsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            let fakeID = "zzzzzz"

            try await app.asyncTest(
                .POST, "/instructor/\(fakeID)/open",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }
}
