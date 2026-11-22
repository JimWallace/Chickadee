// Tests/APITests/Assignments/AssignmentRoutesLifecycleTests.swift
//
// Split from AssignmentRoutesTests.swift.  See AssignmentRoutesTestCase.swift
// for shared helpers (auth, fixtures, multipart builders, zip + notebook
// staging).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AssignmentRoutesLifecycleTests {

    // MARK: - POST /instructor/:id/open

    @Test func openAssignmentSetsIsOpenTrue() async throws {
        try await withTestApp { app in
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
        try await withTestApp { app in
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

    // MARK: - POST /instructor/:id/clone

    @Test func cloneAssignmentCreatesClosedCopyAndRedirectsToEdit() async throws {
        try await withTestApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_clone", on: app)
            // cloneAssignment copies the setup zip off disk — materialize one.
            let zipPath = app.testSetupsDirectory + "setup_clone.zip"
            #expect(FileManager.default.createFile(atPath: zipPath, contents: Data("PK".utf8)))
            let a = try await arInsertAssignment(
                testSetupID: "setup_clone", title: "Lab 1", isOpen: true, on: app)

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/clone",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("/edit") == true)
                })

            // Source is untouched and still open.
            let source = try await APIAssignment.find(a.id, on: app.db)
            #expect(source?.isOpen == true)

            // A new, closed copy "<title> (Copy)" with its own setup now exists.
            let copy = try #require(
                try await APIAssignment.query(on: app.db).all().first { $0.title == "Lab 1 (Copy)" })
            #expect(copy.isOpen == false)
            #expect(copy.publicID != a.publicID)
            #expect(copy.testSetupID != a.testSetupID)
        }
    }

    /// The clone fails after it saves the new setup row: the source has a
    /// reference solution, and the submissions directory that the copy goes
    /// into does not exist. The route runs the clone in one transaction, so
    /// the failure leaves no new `test_setups` row, no assignment and no
    /// copied file (#3214).
    @Test func aFailedCloneLeavesNoSetupRow() async throws {
        try await withTestApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "setup_clone_fail", on: app)
            let zipPath = app.testSetupsDirectory + "setup_clone_fail.zip"
            #expect(FileManager.default.createFile(atPath: zipPath, contents: Data("PK".utf8)))
            let a = try await arInsertAssignment(
                testSetupID: "setup_clone_fail", title: "Lab 2", isOpen: true, on: app)
            let author = try await makeTestUser(on: app, username: "clone_fail_author", role: "admin")
            let solution = try await makeTestSubmission(
                on: app, id: "sub_clone_fail", setupID: "setup_clone_fail",
                userID: try author.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            // Keep the solution file, but outside the submissions directory,
            // and then remove that directory, so the solution copy fails
            // (`copySubmissionFile` does not create the directory).
            let keptPath = app.testSetupsDirectory + "sub_clone_fail.ipynb"
            try FileManager.default.moveItem(atPath: solution.zipPath, toPath: keptPath)
            solution.zipPath = keptPath
            try await solution.save(on: app.db)
            a.validationSubmissionID = try solution.requireID()
            try await a.save(on: app.db)
            try FileManager.default.removeItem(atPath: app.submissionsDirectory)
            let setupsBefore = try await APITestSetup.query(on: app.db).all().compactMap(\.id).sorted()
            let filesBefore = try FileManager.default.contentsOfDirectory(atPath: app.testSetupsDirectory)
                .sorted()

            try await app.asyncTest(
                .POST, "/instructor/\(a.publicID)/clone",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .internalServerError)
                })

            let setupsAfter = try await APITestSetup.query(on: app.db).all().compactMap(\.id).sorted()
            #expect(setupsAfter == setupsBefore)
            let titles = try await APIAssignment.query(on: app.db).all().map(\.title)
            #expect(titles == ["Lab 2"])
            let filesAfter = try FileManager.default.contentsOfDirectory(atPath: app.testSetupsDirectory)
                .sorted()
            #expect(filesAfter == filesBefore)
        }
    }

    // MARK: - POST /instructor/:id/delete

    @Test func deleteAssignmentRemovesRecord() async throws {
        try await withTestApp { app in
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
        try await withTestApp { app in
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
        try await withTestApp { app in
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
