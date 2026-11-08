// Tests/APITests/Auth/UserFileAccessTests.swift
//
// `mayReadUserFile` is the one policy for another user's folder under
// `users/` (#2895), for the static files and the JupyterLite contents API.
// Before #2895, staff in ANY live course read every user's folder, so a TA in
// one course read another course's solution notebooks and students' work.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct UserFileAccessTests {

    private struct World {
        let caller: APIUser
        let owner: String
        let setupID: String
    }

    /// A setup in course "OWN" (archived or not), an owner's folder, and a
    /// caller with `roleInOwn` there and `roleInOther` in another course.
    private func seed(
        on app: Application, callerRole: String = "student", roleInOwn: CourseRole?,
        roleInOther: CourseRole? = nil, archived: Bool = false
    ) async throws -> World {
        let own = try await makeTestCourse(on: app, code: "OWN", archived: archived, mode: .closed)
        let other = try await makeTestCourse(on: app, code: "OTHER", mode: .closed)
        let setupID = "setup_ufa"
        try await makeTestSetup(on: app, id: setupID, courseID: try own.requireID())
        let caller = try await makeTestUser(on: app, username: "ufa-caller", role: callerRole)
        if let roleInOwn {
            try await APICourseEnrollment(
                userID: try caller.requireID(), courseID: try own.requireID(), role: roleInOwn
            ).save(on: app.db)
        }
        if let roleInOther {
            try await APICourseEnrollment(
                userID: try caller.requireID(), courseID: try other.requireID(), role: roleInOther
            ).save(on: app.db)
        }
        return World(caller: caller, owner: UUID().uuidString.lowercased(), setupID: setupID)
    }

    @Test func theOwnerReadsTheirOwnFolder() async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, roleInOwn: .student)
            let own = try world.caller.requireID().uuidString.lowercased()
            #expect(try await mayReadUserFile(world.caller, owner: own, setupID: nil, db: app.db))
            #expect(try await mayReadUserFile(world.caller, owner: own, setupID: world.setupID, db: app.db))
        }
    }

    @Test func anAdminReadsEveryFolder() async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, callerRole: "admin", roleInOwn: nil)
            #expect(try await mayReadUserFile(world.caller, owner: world.owner, setupID: nil, db: app.db))
            #expect(try await mayReadUserFile(world.caller, owner: nil, setupID: nil, db: app.db))
        }
    }

    @Test(arguments: [CourseRole.ta, .instructor])
    func staffOfTheSetupsLiveCourseReadIt(role: CourseRole) async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, roleInOwn: role)
            #expect(try await mayReadUserFile(world.caller, owner: world.owner, setupID: world.setupID, db: app.db))
        }
    }

    @Test func staffOfAnArchivedCourseAreRefused() async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, roleInOwn: .ta, archived: true)
            #expect(try await !mayReadUserFile(world.caller, owner: world.owner, setupID: world.setupID, db: app.db))
        }
    }

    /// The #2895 leak: staff elsewhere, and a student (or nothing) here.
    @Test(arguments: [CourseRole?.none, .some(.student)])
    func staffOfAnotherCourseAreRefused(roleInOwn: CourseRole?) async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, roleInOwn: roleInOwn, roleInOther: .instructor)
            #expect(try await !mayReadUserFile(world.caller, owner: world.owner, setupID: world.setupID, db: app.db))
        }
    }

    /// Above the setup level a listing names every user: owner or admin only.
    @Test func staffCannotListAboveASetup() async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, roleInOwn: .instructor)
            #expect(try await !mayReadUserFile(world.caller, owner: world.owner, setupID: nil, db: app.db))
            #expect(try await !mayReadUserFile(world.caller, owner: nil, setupID: nil, db: app.db))
        }
    }

    @Test func anUnknownSetupIsRefused() async throws {
        try await withTestApp { app in
            let world = try await seed(on: app, roleInOwn: .instructor)
            #expect(try await !mayReadUserFile(world.caller, owner: world.owner, setupID: "no_such", db: app.db))
        }
    }

    @Test(arguments: [
        ("/jupyterlite/files/users/abc/setup_x/assignment.ipynb", "setup_x"),
        ("/jupyterlite//files/users/abc/Setup_X/assignment.ipynb", "Setup_X"),
        ("/jupyterlite/files/users/abc/assignment.ipynb", nil),
        ("/jupyterlite/files/users/abc", nil),
    ])
    func theSetupSegmentIsReadFromTheResolvedPath(path: String, expected: String?) {
        #expect(UserFileNamespaceMiddleware.requestedSetupID(from: path) == expected)
    }
}
