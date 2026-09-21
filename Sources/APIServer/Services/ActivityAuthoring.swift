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

    /// The record a king-of-the-hill kind seeds beside it: the hill's holder.
    static let seededChampionRecordID = "hill_champion"

    /// The record a standings kind seeds: the standings leader.
    static let seededWinnerRecordID = "standings_leader"

    /// The record a bracket kind seeds: the tournament's winner.
    static let seededTournamentRecordID = "tournament_winner"

    /// The refusal for a kind change under live submissions. One message for
    /// the web banner and the MCP error.
    static let kindLockedMessage =
        "This assignment already has student submissions, so its activity kind is locked. "
        + "Clone the assignment to run it as a different kind of activity."

    /// The refusal for an opponent file that is not a support file of the
    /// setup. Names the file, not the list: the picker beside the web banner
    /// already shows the list, and an agent has get_support_files.
    static func opponentFileNotFoundMessage(_ file: String) -> String {
        "Opponent file \"\(file)\" is not a support file of this assignment. "
            + "Upload the bot as a support file first, then select it."
    }

    /// The refusal for naming an opponent file on a kind that has no opponent.
    static func opponentFileOnKindWithoutOpponentMessage(_ kind: ActivityKind) -> String {
        "\(kind.displayName) has no opponent, so it takes no opponent file."
    }

    /// Sets, changes or clears (`nil`) the activity block, returning the block
    /// as stored.
    ///
    /// Refuses a kind change — including setting a kind on an ordinary
    /// assignment and clearing one — once any student submission exists.
    /// Changing only the leaderboard visibility or the opponent file of an
    /// existing activity is always allowed: the first is display policy, and
    /// the second is grading content an instructor may fix mid-lab the way a
    /// test script is.
    ///
    /// Refuses choosing an opponent file on a browser-graded assignment
    /// (`activityOpponentGradingConflictMessage`): only the native worker
    /// builds the opponent directory, so the match would run with nobody on
    /// the other side. `set_grading_mode` refuses the same pair from the mode
    /// side. The kind alone is not refused — a bot kind with no file chosen
    /// stages nothing and grades as it always did.
    ///
    /// Validates the opponent file: it must be a bare filename naming one of
    /// the setup's support files, and a kind with no opponent takes none. A
    /// bot kind may be set with no file — the bot can be uploaded afterwards.
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
        if let activity {
            try await validateOpponent(of: activity, setup: setup)
        }
        try await setManifestActivity(setup: setup, to: activity, on: db)
        if let activity, activity.kind.aggregation == .leaderboard {
            try await seedLeaderboardRecord(setup: setup, on: db)
        } else {
            try await removeSeededRecord(setup: setup, id: seededRecordID, on: db)
        }
        // One held `tournamentWinner` record per non-metric aggregation,
        // named for what it means there; a kind change swaps them. The
        // other aggregation's record goes FIRST, since the seeder declines
        // while any `tournamentWinner` record is on the manifest.
        let aggregation = activity?.kind.aggregation
        if aggregation != .standings {
            try await removeSeededRecord(setup: setup, id: seededWinnerRecordID, on: db)
        }
        if aggregation != .bracket {
            try await removeSeededRecord(setup: setup, id: seededTournamentRecordID, on: db)
        }
        if aggregation == .standings {
            try await seedWinnerRecord(setup: setup, record: seededWinnerRecord, on: db)
        }
        if aggregation == .bracket {
            try await seedWinnerRecord(setup: setup, record: seededTournamentRecord, on: db)
        }
        if activity?.kind.opponentSource == .champion {
            try await seedChampionRecord(setup: setup, on: db)
        } else {
            // A kind change away from the hill (or clearing) takes its
            // seeded record with it; an instructor-authored one stays.
            try await removeSeededRecord(setup: setup, id: seededChampionRecordID, on: db)
        }
        return activity
    }

    private static func validateOpponent(of activity: ClassActivity, setup: APITestSetup) async throws {
        if activity.stagesAnOpponent,
            currentManifestGradingMode(setup.manifest) == GradingMode.browser.rawValue
        {
            throw AppError.badRequest(reason: activityOpponentGradingConflictMessage)
        }
        guard let file = activity.opponentFile else { return }
        guard activity.stagesAnOpponent else {
            throw AppError.badRequest(reason: opponentFileOnKindWithoutOpponentMessage(activity.kind))
        }
        let available = await currentSupportFileNames(setup: setup)
        guard FilenameSafety.bareFilename(file) == file, available.contains(file) else {
            throw AppError.badRequest(reason: opponentFileNotFoundMessage(file))
        }
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

    /// The record a king-of-the-hill kind seeds.
    static let seededChampionRecord = Achievement(
        id: seededChampionRecordID,
        name: "Hill champion",
        detail: "Holds the hill on this assignment.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Champion"),
        recordDimension: .champion)

    /// The record a standings kind seeds.
    static let seededWinnerRecord = Achievement(
        id: seededWinnerRecordID,
        name: "Standings leader",
        detail: "Leads the standings on this assignment.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Leader"),
        recordDimension: .tournamentWinner)

    /// The record a bracket kind seeds.
    static let seededTournamentRecord = Achievement(
        id: seededTournamentRecordID,
        name: "Tournament winner",
        detail: "Won the most recent tournament on this assignment.",
        scope: .record,
        reward: AchievementReward(type: .title, label: "Tournament winner"),
        recordDimension: .tournamentWinner)

    private static func seedWinnerRecord(
        setup: APITestSetup, record: Achievement, on db: any Database
    ) async throws {
        guard let props = setup.decodedManifest() else { return }
        if props.achievements.contains(where: { $0.recordDimension == .tournamentWinner }) { return }
        let authoredIDs = Set(props.achievements.map(\.id))
        let builtIns =
            props.builtInAchievementsSeeded
            ? []
            : BuiltInAchievements.all.filter { !authoredIDs.contains($0.id) }
        let achievements = props.achievements + builtIns + [record]
        try await mutateManifest(setup: setup, on: db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(achievements))
            dict["builtInAchievementsSeeded"] = true
        }
    }

    private static func seedChampionRecord(setup: APITestSetup, on db: any Database) async throws {
        guard let props = setup.decodedManifest() else { return }
        if props.achievements.contains(where: { $0.recordDimension == .champion }) { return }
        // The leaderboard record was seeded first (every hill kind is a
        // leaderboard kind), so the built-ins are already curated here.
        let achievements = props.achievements + [seededChampionRecord]
        try await mutateManifest(setup: setup, on: db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(achievements))
        }
    }

    private static func removeSeededRecord(setup: APITestSetup, id: String, on db: any Database) async throws {
        guard let props = setup.decodedManifest(),
            props.achievements.contains(where: { $0.id == id })
        else { return }
        let remaining = props.achievements.filter { $0.id != id }
        try await mutateManifest(setup: setup, on: db) { dict in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dict["achievements"] = try JSONSerialization.jsonObject(with: encoder.encode(remaining))
        }
    }
}
