// Tests/APITests/AvatarLateAxisFillTests.swift
//
// A spec stored before the tuft and tilt axes existed gets a one-time random
// fill of ONLY those axes on its next load, and is written back. Every slot the
// student already had must survive unchanged: the fill is a draw into an empty
// slot, not a reshuffle (docs/student-avatars.md, decision 2).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AvatarLateAxisFillTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-avatar-fill")
    }

    /// A spec in the stored form it had before the tune-up: six keys, no tuft,
    /// no tilt.
    private static let preTuneUpJSON =
        #"{"cap":"plum","wing":"barred","expression":"wink","accessory":"scarf","accent":"honey","backdrop":"rose"}"#

    @Test func preTuneUpSpecGetsOnlyTheMissingAxesAndIsWrittenBack() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_fill_old")
            user.avatarSpecJSON = Self.preTuneUpJSON
            try await user.save(on: app.db)

            let spec = try await AvatarStore.ensureSpec(for: user, on: app.db)
            #expect(spec.cap == .plum)
            #expect(spec.wing == .barred)
            #expect(spec.expression == .wink)
            #expect(spec.accessory == .scarf)
            #expect(spec.accent == .honey)
            #expect(spec.backdrop == .rose)

            let stored = try #require(
                try await APIUser.find(user.id, on: app.db)?.avatarSpecJSON)
            #expect(AvatarSpec.missingAxes(inStoredJSON: stored).isEmpty, "fill was not written back")
            #expect(AvatarStore.decode(stored) == spec)

            // Once filled, the next load returns the stored bird unchanged.
            let reloaded = try #require(try await APIUser.find(user.id, on: app.db))
            #expect(try await AvatarStore.ensureSpec(for: reloaded, on: app.db) == spec)
        }
    }

    /// A spec that carries one late axis keeps it; only the absent one is drawn.
    @Test func aPresentLateAxisIsKept() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_fill_partial")
            user.avatarSpecJSON =
                #"{"cap":"teal","wing":"plain","expression":"keen","accessory":"none","accent":"moss","backdrop":"sky","tuft":"crest"}"#
            try await user.save(on: app.db)

            let spec = try await AvatarStore.ensureSpec(for: user, on: app.db)
            #expect(spec.tuft == .crest)
            #expect(spec.cap == .teal)
            #expect(spec.expression == .keen)
        }
    }

    /// A current spec is never rewritten, even one whose tuft and tilt are the
    /// defaults: `none` and `upright` stored explicitly are choices, not gaps.
    @Test func aCurrentSpecIsNotRewritten() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_fill_current")
            let current = AvatarSpec(
                cap: .ink, wing: .edged, expression: .bright, accessory: .none, accent: .ember,
                backdrop: .sage, tuft: .none, tilt: .upright)
            let json = try #require(AvatarStore.encode(current))
            user.avatarSpecJSON = json
            try await user.save(on: app.db)

            #expect(try await AvatarStore.ensureSpec(for: user, on: app.db) == current)
            #expect(try await APIUser.find(user.id, on: app.db)?.avatarSpecJSON == json)
        }
    }
}
