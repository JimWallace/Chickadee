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

    /// The refusal for a composite's structure change under live
    /// submissions. Separate from `kindLockedMessage`, which names the kind:
    /// here the kind is unchanged and only the slots would move.
    static let compositeLayoutLockedMessage =
        "This assignment already has student submissions or dealt slots, so the composite's "
        + "compositor, layout, contribution size and deal order are locked. The frame rate and the "
        + "empty-slot settings can still change."

    /// The refusal for a class composite on an assignment that declares no
    /// language. The slot reaches the test script as a per-student input, and
    /// a suite of hand-written shell scripts has no inputs file to carry it.
    static let compositeNeedsLanguageMessage =
        "A class composite needs a declared language: each student's slot reaches the test script "
        + "as a per-student input, and an assignment with no language has no inputs file. Choose the "
        + "assignment's language first."

    /// The refusal for showing a composite's leaderboard page to students:
    /// the composite is for the projector, and each student sees only their
    /// own contribution (docs/class-composite.md).
    static let compositeLeaderboardHiddenMessage =
        "A class composite is shown on the projector only, so its leaderboard stays hidden from "
        + "students. Each student sees their own contribution on their result page."

    /// The refusal for a composite block on a kind that is not a composite.
    static func compositeOnOtherKindMessage(_ kind: ActivityKind) -> String {
        "\(kind.displayName) is not a class composite, so it takes no composite settings."
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
    /// Refuses a kind whose opponent the worker chooses (the hill, round
    /// robin, tests versus implementations) on a browser-graded assignment
    /// (`activityOpponentGradingConflictMessage`): the browser has no claim
    /// step, so the match would run with nobody on the other side.
    /// `set_grading_mode` refuses the same pair from the mode side. A bot
    /// kind is not refused: the browser runner stages the bot.
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
    ///
    /// A class composite always carries a `composite` block: a composite
    /// chosen without one keeps the stored block when the kind is unchanged
    /// and gets `CompositeSpec.starter` otherwise, so the edit page's kind
    /// select alone makes a valid activity. The block's structure locks with
    /// the kind (`compositeLayoutLockedMessage`); its display settings do not.
    ///
    /// `lockDB` answers the two lock questions (a student submission, a dealt
    /// slot). MCP passes the owner pool: the least-privilege MCP role cannot
    /// read `composite_slots`, and it reads `submissions` filtered to
    /// validation runs, so on its own pool both locks would always read as
    /// open. Every other caller reads on `db`.
    @discardableResult
    static func setActivity(
        setup: APITestSetup, to requested: ClassActivity?, on db: any Database,
        lockDB: (any Database)? = nil
    ) async throws -> ClassActivity? {
        let lockDB = lockDB ?? db
        let current = currentManifestActivity(setup.manifest)
        if current?.kind != requested?.kind, try await hasStudentSubmissions(setup: setup, on: lockDB) {
            throw AppError.badRequest(reason: kindLockedMessage)
        }
        let activity = try requested.map { try withSeededComposite($0, current: current) }
        if let activity {
            try await validateOpponent(of: activity, setup: setup)
            try validateWindow(of: activity)
            try await validateRunsPerGroup(of: activity, courseID: setup.courseID, on: lockDB)
            try await validateComposite(of: activity, current: current, setup: setup, on: lockDB)
        }
        try await setManifestActivity(setup: setup, to: activity, on: db)
        if activity?.runsPerGroup != true {
            try await ActivitySessionStore.closeOpenSessions(testSetupID: setup.requireID(), on: lockDB)
        }
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

    /// Refuses a live-session window that closes before it opens.
    ///
    /// Such a window accepts nothing, ever, which no author means — and it
    /// would refuse every submission with a message naming a time already
    /// past, so the instructor would be debugging the contest rather than
    /// the typo. Shared by both doors, like the opponent checks beside it.
    private static func validateWindow(of activity: ClassActivity) throws {
        guard let window = activity.window else { return }
        // Refused here so a stored bound is always one somebody wrote on
        // purpose. The window itself fails OPEN on a bound it cannot read,
        // which is the right answer at grading time and the wrong one to
        // reach by accident.
        guard window.boundsAreReadable else {
            throw AppError.badRequest(reason: windowBoundsUnreadableMessage)
        }
        guard window.boundsAreOrdered else {
            throw AppError.badRequest(reason: windowBoundsOutOfOrderMessage)
        }
    }

    /// Refuses a per-group activity (docs/lab-groups.md) in a course with no
    /// group set, since its sessions would have no group to run in, and one
    /// that also carries a window, since each group's session replaces the
    /// window as the clock and a stored window nobody reads misleads.
    ///
    /// Reads the group sets on `db`, which the MCP caller passes as the owner
    /// pool: the least-privilege MCP role cannot read them.
    private static func validateRunsPerGroup(
        of activity: ClassActivity, courseID: UUID, on db: any Database
    ) async throws {
        guard activity.runsPerGroup else { return }
        // A composite deals its slots course-wide until slice 4 deals them
        // per group, so it cannot run per group yet.
        guard activity.kind.aggregation != .composite else {
            throw AppError.badRequest(reason: runsPerGroupCompositeMessage)
        }
        guard activity.window == nil else {
            throw AppError.badRequest(reason: runsPerGroupWithWindowMessage)
        }
        guard try await !CourseGroupStore.sets(courseID: courseID, on: db).isEmpty else {
            throw AppError.badRequest(reason: runsPerGroupNeedsGroupsMessage)
        }
    }

    static let runsPerGroupNeedsGroupsMessage =
        "This course has no lab groups yet, so make them on the Groups tab first."
    static let runsPerGroupCompositeMessage =
        "A class composite cannot run once per lab group yet."
    static let runsPerGroupWithWindowMessage =
        "Each group's session is the clock of a per-group activity, so clear the session window first."

    /// The requested block with its composite settled: kept or seeded for a
    /// class composite, refused on any other kind.
    private static func withSeededComposite(
        _ activity: ClassActivity, current: ClassActivity?
    ) throws -> ClassActivity {
        guard activity.kind == .classComposite else {
            guard activity.composite == nil else {
                throw AppError.badRequest(reason: compositeOnOtherKindMessage(activity.kind))
            }
            return activity
        }
        guard activity.leaderboardVisibility == .hidden else {
            throw AppError.badRequest(reason: compositeLeaderboardHiddenMessage)
        }
        guard activity.composite == nil else { return activity }
        let kept = current?.kind == .classComposite ? current?.composite : nil
        return activity.withComposite(kept ?? .starter)
    }

    /// Refuses a composite on an assignment with no language, a composite
    /// block that breaks a `CompositeSpec` rule, and a change to its
    /// structure once a slot is dealt or a student has submitted.
    private static func validateComposite(
        of activity: ClassActivity, current: ClassActivity?, setup: APITestSetup, on lockDB: any Database
    ) async throws {
        guard let composite = activity.composite else { return }
        guard let manifest = setup.decodedManifest(), AssignmentLanguage.resolve(manifest: manifest) != nil else {
            throw AppError.badRequest(reason: compositeNeedsLanguageMessage)
        }
        if let problem = composite.problem {
            throw AppError.badRequest(reason: problem.message)
        }
        if current?.kind == .classComposite, let stored = current?.composite,
            !stored.hasSameStructure(as: composite),
            try await compositeStructureLocked(setup: setup, on: lockDB)
        {
            throw AppError.badRequest(reason: compositeLayoutLockedMessage)
        }
    }

    /// True once a student has submitted or a slot has been dealt: each
    /// student's slot and the size the grader checks depend on the structure.
    static func compositeStructureLocked(setup: APITestSetup, on db: any Database) async throws -> Bool {
        if try await hasStudentSubmissions(setup: setup, on: db) { return true }
        guard let setupID = setup.id, let assignment = try await assignmentByTestSetupID(setupID, on: db),
            let assignmentID = assignment.id
        else { return false }
        return try await CompositeSlots.hasDealtSlots(assignmentID: assignmentID, on: db)
    }

    static let windowBoundsOutOfOrderMessage =
        "A class activity's window must close after it opens."

    static let windowBoundsUnreadableMessage =
        "A class activity's window needs ISO-8601 times, for example 2026-09-22T14:00:00Z."

    private static func validateOpponent(of activity: ClassActivity, setup: APITestSetup) async throws {
        if activity.kind.opponentSource.opponentNeedsWorker,
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
    /// The record dimension `setActivity` seeds for an aggregation; nil for
    /// a union or composite kind, which seeds none. The seeders decline while a record of
    /// that dimension is already on the manifest, so an instructor's own
    /// record counts. One exhaustive switch, so the `set_activity` report
    /// cannot answer for the leaderboard alone (#2190).
    static func seededRecordDimension(for aggregation: ActivityAggregation) -> RecordDimension? {
        switch aggregation {
        case .leaderboard: return .highestMetric
        case .standings, .bracket: return .tournamentWinner
        case .union, .composite: return nil
        }
    }

    /// True when the manifest holds the record its activity's aggregation
    /// seeds. False with no activity and for a union kind.
    static func hasSeededRecord(_ props: TestProperties) -> Bool {
        guard let aggregation = props.activity?.kind.aggregation,
            let dimension = seededRecordDimension(for: aggregation)
        else { return false }
        return props.achievements.contains { $0.recordDimension == dimension }
    }

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
        try await mutateManifest(setup: setup, on: db) { props in
            props.achievements = achievements
            props.builtInAchievementsSeeded = true
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
        try await mutateManifest(setup: setup, on: db) { props in
            props.achievements = achievements
            props.builtInAchievementsSeeded = true
        }
    }

    private static func seedChampionRecord(setup: APITestSetup, on db: any Database) async throws {
        guard let props = setup.decodedManifest() else { return }
        if props.achievements.contains(where: { $0.recordDimension == .champion }) { return }
        // The leaderboard record was seeded first (every hill kind is a
        // leaderboard kind), so the built-ins are already curated here.
        let achievements = props.achievements + [seededChampionRecord]
        try await mutateManifest(setup: setup, on: db) { props in
            props.achievements = achievements
        }
    }

    private static func removeSeededRecord(setup: APITestSetup, id: String, on db: any Database) async throws {
        guard let props = setup.decodedManifest(),
            props.achievements.contains(where: { $0.id == id })
        else { return }
        let remaining = props.achievements.filter { $0.id != id }
        try await mutateManifest(setup: setup, on: db) { props in
            props.achievements = remaining
        }
    }
}
