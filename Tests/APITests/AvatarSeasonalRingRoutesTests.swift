// Tests/APITests/AvatarSeasonalRingRoutesTests.swift
//
// The seasonal rings on the account page (docs/student-wardrobe.md,
// "Seasonal rings"). The page reads today's Waterloo term, so each test
// works out which ring is in season instead of fixing a date.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AvatarSeasonalRingRoutesTests {

    private static var inSeason: AvatarBorder {
        AvatarBorder.allCases.first { $0.season == TermSeason.current() } ?? .none
    }

    private static var outOfSeason: [AvatarBorder] {
        AvatarBorder.allCases.filter { $0.availability == .seasonal && $0 != inSeason }
    }

    // MARK: - Labels

    /// A seasonal ring names its term whether or not it is open: "Maple ·
    /// Fall" among the open rings, "Maple · Fall term" under "Not open yet".
    /// Any other locked ring is earned.
    @Test func aSeasonalRingAlwaysNamesItsTerm() {
        #expect(AvatarPickerContext.borderLabel(.maple, isLocked: true) == "Maple · Fall term")
        #expect(AvatarPickerContext.borderLabel(.snowflake, isLocked: true) == "Snowflake · Winter term")
        #expect(AvatarPickerContext.borderLabel(.blossom, isLocked: true) == "Blossom · Spring term")
        #expect(AvatarPickerContext.borderLabel(.spectrum, isLocked: true) == "Spectrum · earned")
        #expect(AvatarPickerContext.borderLabel(.maple, isLocked: false) == "Maple · Fall")
        #expect(AvatarPickerContext.borderLabel(.rainbow, isLocked: false) == "Rainbow")
    }

    // MARK: - The page and the post

    private func post(
        _ fields: [String: String], cookie: String, on app: Application
    ) async throws
        -> String?
    {
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        var location: String?
        try await app.asyncTest(
            .POST, "/account/avatar",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in location = res.headers.first(name: .location) })
        return location
    }

    @Test func theRingOfTheTermIsOpenAndTheOthersNameTheirTerm() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginUser(
                username: "season_page", password: "pw", role: "user", on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            let open = Self.inSeason
            #expect(html.contains("value=\"\(open.rawValue)\""))
            #expect(html.contains(##"data-av-season="\##(try #require(open.season).rawValue)""##))
            #expect(html.contains(##"name="border" value="\##(open.rawValue)""##))
            #expect(html.contains("\(open.displayName) · \(try #require(open.season).displayName)<"))
            for ring in Self.outOfSeason {
                let term = try #require(ring.season).displayName
                #expect(!html.contains(##"name="border" value="\##(ring.rawValue)""##), "\(ring) is an input")
                #expect(html.contains("\(ring.displayName) · \(term) term"))
            }
        }
    }

    @Test func aStudentCanSaveTheRingOfTheTermButNotAnother() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginUser(
                username: "season_post", password: "pw", role: "user", on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)

            let other = try #require(Self.outOfSeason.first)
            #expect(
                try await post(["border": other.rawValue], cookie: cookie, on: app)
                    == "/account?avatar=invalid#chickadee")

            #expect(
                try await post(["border": Self.inSeason.rawValue], cookie: cookie, on: app)
                    == "/account?avatar=saved#chickadee")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "season_post").first())
            let spec = try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
            #expect(spec.border == Self.inSeason)
        }
    }

    /// A student who wears a ring out of its term sees it checked and
    /// selectable, not dimmed: the ring is theirs to keep.
    @Test func aWornRingOutOfItsTermIsCheckedAndNotDisabled() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginUser(
                username: "season_worn", password: "pw", role: "user", on: app)
            _ = try await getHTML("/account", cookie: cookie, on: app)
            let worn = try #require(Self.outOfSeason.first)
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "season_worn").first())
            var spec = try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
            spec.border = worn
            user.avatarSpecJSON = AvatarStore.encode(spec)
            try await user.save(on: app.db)

            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(html.contains(##"value="\##(worn.rawValue)" data-av-token="--avatar-border-none" checked>"##))
            #expect(!html.contains("\(worn.displayName) · \(try #require(worn.season).displayName) term"))

            #expect(
                try await post(["border": worn.rawValue], cookie: cookie, on: app)
                    == "/account?avatar=saved#chickadee")
        }
    }
}
