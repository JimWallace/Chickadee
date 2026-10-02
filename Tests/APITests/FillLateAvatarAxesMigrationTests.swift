// Tests/APITests/FillLateAvatarAxesMigrationTests.swift
//
// A bird stored before the tuft and tilt axes existed gets a one-time random
// fill of ONLY those axes from `FillLateAvatarAxes` (#1762). Every slot the
// student already had must survive unchanged: the fill is a draw into an empty
// slot, not a reshuffle (docs/student-avatars.md, decision 2). The store itself
// no longer fills on read, so a stored bird comes back as stored.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class FillLateAvatarAxesMigrationTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-avatar-fill")
    }

    /// A spec in the stored form it had before the tune-up: six keys, no tuft,
    /// no tilt.
    private static let preTuneUpJSON =
        #"{"cap":"plum","wing":"barred","expression":"wink","accessory":"scarf","accent":"honey","backdrop":"rose"}"#

    /// One late axis present, one absent.
    private static let tuftOnlyJSON =
        #"{"cap":"teal","wing":"plain","expression":"keen","accessory":"none","accent":"moss","backdrop":"sky","tuft":"crest"}"#

    private func storedJSON(of user: APIUser) async throws -> String {
        try #require(try await APIUser.find(user.id, on: app.db)?.avatarSpecJSON)
    }

    @Test func theMigrationFillsOnlyTheMissingAxes() async throws {
        try await withApp(app) { _ in
            let old = try await makeTestStudent(on: app, username: "av_fill_old")
            old.avatarSpecJSON = Self.preTuneUpJSON
            try await old.save(on: app.db)
            let partial = try await makeTestStudent(on: app, username: "av_fill_partial")
            partial.avatarSpecJSON = Self.tuftOnlyJSON
            try await partial.save(on: app.db)
            let current = try await makeTestStudent(on: app, username: "av_fill_current")
            let currentSpec = AvatarSpec(
                cap: .ink, wing: .edged, expression: .bright, accessory: .none, accent: .ember,
                backdrop: .sage, tuft: .none, tilt: .upright)
            let currentJSON = try #require(AvatarStore.encode(currentSpec))
            current.avatarSpecJSON = currentJSON
            try await current.save(on: app.db)

            try await FillLateAvatarAxes().prepare(on: app.db)

            let filled = try await storedJSON(of: old)
            #expect(AvatarSpec.missingAxes(inStoredJSON: filled).isEmpty, "the fill was not written")
            let spec = try #require(AvatarStore.decode(filled))
            #expect(spec.cap == .plum)
            #expect(spec.wing == .barred)
            #expect(spec.expression == .wink)
            #expect(spec.accessory == .scarf)
            #expect(spec.accent == .honey)
            #expect(spec.backdrop == .rose)

            // The present axis is kept; only the absent one is drawn.
            let kept = try await storedJSON(of: partial)
            #expect(AvatarSpec.missingAxes(inStoredJSON: kept).isEmpty)
            let keptSpec = try #require(AvatarStore.decode(kept))
            #expect(keptSpec.tuft == .crest)
            #expect(keptSpec.cap == .teal)
            #expect(keptSpec.expression == .keen)

            // A current spec is not rewritten, even one whose tuft and tilt
            // are the defaults: `none` and `upright` stored explicitly are
            // choices, not gaps.
            #expect(try await storedJSON(of: current) == currentJSON)
        }
    }

    /// The migration is the only writer: a bird the store reads comes back as
    /// stored, so a pre-tune-up row the migration has not yet reached decodes
    /// with the defaults and is left for the migration, not filled on view.
    @Test func theStoreReturnsAStoredBirdAsStored() async throws {
        try await withApp(app) { _ in
            let user = try await makeTestStudent(on: app, username: "av_fill_store")
            user.avatarSpecJSON = Self.preTuneUpJSON
            try await user.save(on: app.db)

            let spec = try await AvatarStore.ensureSpec(for: user, on: app.db)
            #expect(spec.cap == .plum)
            #expect(spec.tuft == .none)
            #expect(spec.tilt == .upright)
            #expect(try await storedJSON(of: user) == Self.preTuneUpJSON)
        }
    }
}
