// Tests/APITests/Auth/APIUserSessionLookupTests.swift
//
// The session authenticator loads the signed-in user through
// `APIUserSessionLookup` (SQLKit) in place of Fluent's `find` (#2905). The
// user must be the same model in the same fetched state: some routes save the
// signed-in user, and a save must write only the fields it changed.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class APIUserSessionLookupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-user-lookup")
    }

    private func makeUser() async throws -> APIUser {
        let user = APIUser(
            username: "lookup_student", passwordHash: "hash", role: "user",
            email: "lookup@example.edu", preferredName: nil, studentID: "20001234")
        user.avatarSpecJSON = "{\"species\":\"chickadee\"}"
        try await user.save(on: app.db)
        return user
    }

    @Test func theLookupLoadsTheSameUserAsFind() async throws {
        try await withApp(app) { app in
            let id = try await makeUser().requireID()
            let found = try #require(try await APIUser.find(id, on: app.db))
            let looked = try #require(try await APIUserSessionLookup.find(id, on: app.db))

            #expect(looked.id == found.id)
            #expect(looked.username == found.username)
            #expect(looked.passwordHash == found.passwordHash)
            #expect(looked.role == found.role)
            #expect(looked.email == found.email)
            #expect(looked.preferredName == found.preferredName)
            #expect(looked.studentID == found.studentID)
            #expect(looked.displayName == found.displayName)
            #expect(looked.avatarSpecJSON == found.avatarSpecJSON)
            #expect(looked.createdAt == found.createdAt)
            #expect(looked.$id.exists)
            #expect(!looked.hasChanges)
        }
    }

    /// A save writes only what changed, as it does for a user from `find`, so
    /// it cannot put back a column that another request changed meanwhile.
    @Test func aSaveWritesOnlyTheChangedFields() async throws {
        try await withApp(app) { app in
            let id = try await makeUser().requireID()
            let looked = try #require(try await APIUserSessionLookup.find(id, on: app.db))

            try await APIUser.query(on: app.db).filter(\.$id == id).set(\.$role, to: "admin").update()
            looked.avatarSpecJSON = "{\"species\":\"wren\"}"
            try await looked.save(on: app.db)

            let stored = try #require(try await APIUser.find(id, on: app.db))
            #expect(stored.role == "admin")
            #expect(stored.avatarSpecJSON == "{\"species\":\"wren\"}")
        }
    }

    @Test func aMissingUserIsNil() async throws {
        try await withApp(app) { app in
            let missing = try await APIUserSessionLookup.find(UUID(), on: app.db)
            #expect(missing == nil)
        }
    }
}
