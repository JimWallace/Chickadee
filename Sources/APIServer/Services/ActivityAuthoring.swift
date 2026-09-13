// APIServer/Services/ActivityAuthoring.swift
//
// Shared core for setting an assignment's class-activity block, used by the
// web edit page and the MCP `set_activity` tool so both enforce one lifecycle
// rule and seed the same defaults (docs/class-activities.md).
//
// THE KIND IS LOCKED ONCE A STUDENT HAS SUBMITTED — the same rule as the
// language, for the same reason: a kind decides what the runner does with a
// submission and what the class aggregation means, and there is no migration
// from an individual lab to a competition under live submissions. The
// leaderboard's visibility is a display setting and may change at any time.

import Core
import Fluent
import Foundation

enum ActivityAuthoring {

    /// The record achievement a leaderboard kind seeds, keyed by this id so a
    /// second `set_activity` call does not seed a second one.
    static let seededRecordID = "leaderboard_record"

    /// The refusal for a kind change under live submissions. One message for
    /// the web banner and the MCP error.
    static let kindLockedMessage =
        "This assignment already has student submissions, so its activity kind is locked. "
        + "Clone the assignment to run it as a different kind of activity."

    /// Sets, changes or clears (`nil`) the activity block, returning the block
    /// as stored.
    ///
    /// Refuses a kind change — including setting a kind on an ordinary
    /// assignment and clearing one — once any student submission exists.
    /// Changing only the leaderboard visibility of an existing activity is
    /// always allowed.
    ///
    /// Setting a leaderboard kind seeds one `record` achievement on
    /// `highestMetric` (the kind's default reward) unless the manifest already
    /// carries one; clearing removes the seeded record by id and leaves any
    /// the instructor authored. Seeding goes through the same curation step
    /// the achievements editor uses: the first authored record would
    /// otherwise silence the built-in records (`classRecordsForAward` treats a
    /// non-empty manifest list as authoritative), so the built-ins are seeded
    /// alongside it exactly as a first Save of the Achievements table would.
    @discardableResult
    static func setActivity(
        setup: APITestSetup, to activity: ClassActivity?, on db: any Database
    ) async throws -> ClassActivity? {
        let current = currentManifestActivity(setup.manifest)
        if current?.kind != activity?.kind, try await hasStudentSubmissions(setup: setup, on: db) {
            throw AppError.badRequest(reason: kindLockedMessage)
        }
        try await setManifestActivity(setup: setup, to: activity, on: db)
        if let activity, activity.kind.aggregatesToLeaderboard {
            try await seedLeaderboardRecord(setup: setup, on: db)
        } else if activity == nil {
            try await removeSeededRecord(setup: setup, on: db)
        }
        return activity
    }

    /// True once any student submission exists for the setup — the lock.
    static func hasStudentSubmissions(setup: APITestSetup, on db: any Database) async throws -> Bool {
        guard let setupID = setup.id else { return false }
        return try await APISubmission.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .count() > 0
    }

    /// The record a leaderboard kind seeds.
    static let seededRecord = Achievement(
        id: seededRecordID,
        name: "Leaderboard record",
        detail: "Holds the highest ranking metric on this assignment's leaderboard.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Record holder"),
        recordDimension: .highestMetric)

    private static func seedLeaderboardRecord(setup: APITestSetup, on db: any Database) async throws {
        guard let props = setup.decodedManifest() else { return }
        if props.achievements.contains(where: { $0.recordDimension == .highestMetric }) { return }
        // Curate first, as the editor's first Save does, so adding one record
        // does not silently drop Pathfinder and friends.
        let authoredIDs = Set(props.achievements.map(\.id))
        let builtIns =
            props.builtInAchievementsSeeded
            ? []
            : BuiltInAchievements.all.filter { !authoredIDs.contains($0.id) }
        let achievements = props.achievements + builtIns + [seededRecord]
        try await mutateManifest(setup: setup, on: db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(achievements))
            dict["builtInAchievementsSeeded"] = true
        }
    }

    private static func removeSeededRecord(setup: APITestSetup, on db: any Database) async throws {
        guard let props = setup.decodedManifest(),
            props.achievements.contains(where: { $0.id == seededRecordID })
        else { return }
        let remaining = props.achievements.filter { $0.id != seededRecordID }
        try await mutateManifest(setup: setup, on: db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(remaining))
        }
    }
}
