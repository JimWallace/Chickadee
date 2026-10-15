// Tests/APITests/AccountLifeListTests.swift
//
// The life list on the account page (#2593): a hatch records the species it
// came from and went to, the bird card lists every species with the ones the
// student has had named, and the export carries the hatch species.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class AccountLifeListTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-life-list")
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
            #expect(try await AvatarStore.lifeList(for: student, on: app.db) == [previous.species, current.species])
        }
    }

    @Test func theCardListsEverySpeciesAndNamesTheOnesHad() async throws {
        try await withApp(app) { _ in
            let cookie = try await hatchedStudent("life_page")
            let html = try await getHTML("/account", cookie: cookie, on: app)
            let student = try await user("life_page")
            let seen = try await AvatarStore.lifeList(for: student, on: app.db)

            #expect(html.contains("class=\"bird-life-list\""))
            #expect(html.contains("Life list</strong> · \(seen.count) of \(AvatarSpecies.allCases.count) species"))
            #expect(
                html.components(separatedBy: "class=\"bird-life-list-unseen\"").count - 1
                    == AvatarSpecies.allCases.count - seen.count)
            // Read the list itself, not the rest of the card.
            let start = try #require(html.range(of: "class=\"bird-life-list\""))
            let end = try #require(html[start.upperBound...].range(of: "</ul>"))
            let list = html[start.upperBound..<end.lowerBound]
            for species in AvatarSpecies.allCases {
                let named = list.contains("<span>\(species.displayName)</span>")
                let hidden = list.contains("\(species.displayName), not yet")
                #expect(named == seen.contains(species), "\(species)")
                #expect(hidden == !seen.contains(species), "\(species)")
            }
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
