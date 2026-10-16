// Tests/APITests/AccountHatchSpeciesTests.swift
//
// The hatch species (#2593): a hatch records the species it came from and
// went to, and the export carries them.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class AccountHatchSpeciesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-hatch-species")
    }

    private func user(_ username: String) async throws -> APIUser {
        try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
    }

    /// Logs in a fresh student, draws their bird, and hatches once.
    private func hatchedStudent(_ username: String) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        _ = try await getHTML("/account", cookie: cookie, on: app)
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        try await app.asyncTest(
            .POST, "/account/avatar/hatch",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in #expect(res.headers.first(name: .location) == "/account?avatar=hatched#bird") })
        return newCookie
    }

    @Test func aHatchRecordsBothSpecies() async throws {
        try await withApp(app) { _ in
            _ = try await hatchedStudent("life_record")
            let student = try await user("life_record")
            let row = try #require(
                try await APIAvatarHatch.query(on: app.db).filter(\.$userID == student.requireID()).first())
            let previous = try #require(student.avatarPreviousSpecJSON.flatMap(AvatarStore.decode))
            let current = try #require(student.avatarSpecJSON.flatMap(AvatarStore.decode))
            #expect(row.fromSpecies == previous.species.rawValue)
            #expect(row.species == current.species.rawValue)
        }
    }

    @Test func theExportCarriesTheHatchSpecies() async throws {
        try await withApp(app) { _ in
            _ = try await hatchedStudent("life_export")
            let student = try await user("life_export")
            let content = try await gatherDataExportContent(for: student, on: app.db)
            let hatch = try #require(content.profile.avatarHatches?.first)
            #expect(hatch.fromSpecies != nil)
            #expect(hatch.species != nil)
            #expect(hatch.fromSpecies != hatch.species)
        }
    }
}
