// APIServer/Routes/Web/WebRoutes+Leaderboard.swift
//
// GET /testsetups/:testSetupID/leaderboard — a class activity's ranking
// (docs/class-activities.md). Reached by students through the vanity path
// `/:courseCode/:assignmentSlug/leaderboard` and from their submission page.
//
// Students are named by their per-course handle and their chickadee, never by
// name: the avatar is the identity primitive the leaderboard was designed on
// (docs/student-avatars.md §3), and this page has no identity code of its own.
// Course staff see a real name beside the handle, because a grading dispute
// needs the mapping and nobody else does.
//
// Hidden by default. A student reaches a hidden leaderboard as a 404 — the
// same answer the vanity routes give for anything a student is not meant to
// enumerate — and staff always reach it, with a chip saying it is hidden.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    @Sendable
    func leaderboardPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db),
            let activity = setup.decodedManifest()?.activity,
            activity.kind.aggregatesToLeaderboard
        else { throw Abort(.notFound) }

        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        if !isStaff {
            try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
            guard activity.leaderboardVisibleToStudents else { throw Abort(.notFound) }
        }

        let assignment = try await assignmentByTestSetupID(setupID, on: req.db)
        let rows = try await buildLeaderboardRows(
            setup: setup, viewerID: user.id, includeNames: isStaff, on: req.db)
        let champion = try await buildChampionPresentation(
            setup: setup, activity: activity, viewerID: user.id, includeNames: isStaff, on: req.db)

        return try await req.view.render(
            "leaderboard",
            LeaderboardContext(
                testSetupID: setupID,
                assignmentTitle: assignment?.title ?? setupID,
                kindLabel: activity.kind.displayName,
                isStaff: isStaff,
                visibleToStudents: activity.leaderboardVisibleToStudents,
                rows: rows,
                hasHill: activity.kind.opponentSource == .champion,
                champion: champion,
                currentUser: req.currentUserContext))
    }
}

/// The hill's holder for the page, or nil when the activity has no hill or
/// no student holds it yet (the bot, or nobody, does). Same handle-and-bird
/// identity as a ranking row; staff also see the name.
func buildChampionPresentation(
    setup: APITestSetup, activity: ClassActivity, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> ChampionPresentation? {
    guard activity.kind.opponentSource == .champion,
        let champion = try await currentChampion(testSetupID: setup.id ?? "", on: db),
        let user = try await APIUser.find(champion.userID, on: db),
        let enrollment = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == setup.courseID)
            .filter(\.$userID == champion.userID)
            .first()
    else { return nil }
    let handle = try await AvatarStore.ensureHandle(for: enrollment, on: db) ?? ""
    let spec = try await AvatarStore.ensureSpec(for: user, on: db)
    let accessibility: AvatarAccessibility = handle.isEmpty ? .labelled("Champion") : .decorative
    // The model requires the date; the fallback only keeps the two strings
    // non-optional so the template has no empty shape to render.
    let crownedAt = champion.crownedAt ?? Date()
    return ChampionPresentation(
        handle: handle,
        name: includeNames ? staffFacingName(user) : "",
        crownedAtISO: ISO8601DateFormatter().string(from: crownedAt),
        crownedAtText: waterlooDateTimeFormatter().string(from: crownedAt),
        defencesText: champion.defences == 1 ? "1 defence" : "\(champion.defences) defences",
        isViewer: champion.userID == viewerID,
        avatar: AvatarPresentation(for: spec, size: .small, accessibility: accessibility))
}

// MARK: - Context

struct LeaderboardContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    /// The activity kind's chrome label, e.g. "Best metric".
    let kindLabel: String
    /// Staff see real names and the hidden-from-students chip.
    let isStaff: Bool
    let visibleToStudents: Bool
    let rows: [LeaderboardRow]
    /// True for a king-of-the-hill activity: the page shows who holds the
    /// hill, or that the bot still does.
    let hasHill: Bool
    /// The hill's holder; nil when no student holds it yet.
    let champion: ChampionPresentation?
    let currentUser: CurrentUserContext?
}

/// The hill's holder as the leaderboard shows them.
struct ChampionPresentation: Encodable {
    let handle: String
    /// Staff only; empty for a student viewer.
    let name: String
    /// When the hill was taken: the ISO instant the relative-time script
    /// renders from, and the absolute text it shows without JS.
    let crownedAtISO: String
    let crownedAtText: String
    /// "3 defences".
    let defencesText: String
    let isViewer: Bool
    let avatar: AvatarPresentation
}

struct LeaderboardRow: Encodable {
    /// Competition ranking: equal metrics share a rank and the next rank skips.
    let rank: Int
    /// The per-course pseudonym. Empty only when the course has exhausted the
    /// handle space, in which case the bird alone identifies the row.
    let handle: String
    /// The real name, staff only; empty for a student viewer.
    let name: String
    let metricText: String
    /// True on the viewer's own row.
    let isViewer: Bool
    let avatar: AvatarPresentation
}

// MARK: - Rows

/// The ranking rows for `setup`, best first. Handles and avatars are
/// materialised on first view (`AvatarStore`), so a student who has never
/// opened their account page still appears under a stable pseudonym.
///
/// Batched: one query for the users, one for the course's enrollments; the
/// per-row calls only write when a handle or spec is missing, which happens
/// once per student for the life of the course.
func buildLeaderboardRows(
    setup: APITestSetup, viewerID: UUID?, includeNames: Bool, on db: Database
) async throws -> [LeaderboardRow] {
    let entries = try await leaderboardEntries(testSetupID: setup.id ?? "", on: db)
    guard !entries.isEmpty else { return [] }

    let userIDs = Array(Set(entries.map(\.userID)))
    let users = try await APIUser.query(on: db).filter(\.$id ~~ userIDs).all()
    var userByID: [UUID: APIUser] = [:]
    for user in users { if let id = user.id { userByID[id] = user } }

    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == setup.courseID)
        .filter(\.$userID ~~ userIDs)
        .all()
    var enrollmentByUser: [UUID: APICourseEnrollment] = [:]
    for enrollment in enrollments { enrollmentByUser[enrollment.userID] = enrollment }

    var rows: [LeaderboardRow] = []
    var rank = 0
    var previousMetric: Double?
    for (index, entry) in entries.enumerated() {
        // A student who has since dropped keeps no row: the roster is what a
        // classmate is ranked against, and their enrollment carried the handle.
        guard let user = userByID[entry.userID],
            let enrollment = enrollmentByUser[entry.userID]
        else { continue }
        if entry.metric != previousMetric {
            rank = index + 1
            previousMetric = entry.metric
        }
        let handle = try await AvatarStore.ensureHandle(for: enrollment, on: db) ?? ""
        let spec = try await AvatarStore.ensureSpec(for: user, on: db)
        // Decorative when the handle carries the identity; the bird must
        // announce whose it is only when there is no handle beside it.
        let accessibility: AvatarAccessibility =
            handle.isEmpty ? .labelled("Student \(rank)") : .decorative
        rows.append(
            LeaderboardRow(
                rank: rank,
                handle: handle,
                name: includeNames ? staffFacingName(user) : "",
                metricText: formatLeaderboardMetric(entry.metric),
                isViewer: entry.userID == viewerID,
                avatar: AvatarPresentation(for: spec, size: .small, accessibility: accessibility)))
    }
    return rows
}

/// The name staff see beside a handle: the display name when the roster has
/// one, else the username.
private func staffFacingName(_ user: APIUser) -> String {
    let display = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return display.isEmpty ? user.username : display
}

/// A metric as the page prints it: an integer stays an integer ("1234"), a
/// fraction keeps up to three decimals with no trailing zeros ("0.75").
func formatLeaderboardMetric(_ metric: Double) -> String {
    if metric == metric.rounded(), abs(metric) < 1e15 {
        return String(format: "%.0f", metric)
    }
    var text = String(format: "%.3f", metric)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}
