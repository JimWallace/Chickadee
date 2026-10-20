// APIServer/Routes/Web/InstructorDashboardRoutes+Achievements.swift
//
// The course Achievements tab (docs/achievement-rewards.md, S4).
//
//   GET  /instructor/achievements            → InstructorAchievementsPage
//   GET  /instructor/achievements/rows       → the active course's rows (JSON)
//   PUT  /instructor/achievements/rows       → replace them (JSON)
//   POST /instructor/achievements/recompute  → grant every enrolled student
//
// The `/instructor` gate admits course staff to read. Every write needs a TA
// or above in a course that is not archived (decision 9). A course
// achievement changes no grade, so a save retests nothing.

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    enum AchievementsNotice: String {
        case recomputed

        var text: String {
            switch self {
            case .recomputed: "Recomputed the course achievements of every student."
            }
        }
    }

    /// The Achievements tab routes, under the `/instructor` group.
    func registerAchievementRoutes(on r: any RoutesBuilder) {
        r.get("achievements", use: achievementsPage)
        r.get("achievements", "rows", use: getCourseAchievements)
        r.put("achievements", "rows", use: putCourseAchievements)
        r.post("achievements", "recompute", use: recomputeCourseAchievements)
    }

    // MARK: - Page

    @Sendable
    func achievementsPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let course = try await activeCourse(req: req, user: user)
        let notice = req.query[String.self, at: "notice"].flatMap(AchievementsNotice.init(rawValue:))
        var targets = CourseAchievementTargetOptions(sections: [], assignments: [])
        var earned: [CourseAchievementEarnedRow] = []
        if let course {
            targets = try await Self.targetOptions(for: course, on: req.db)
            earned = try await Self.earnedRows(for: course, on: req.db)
        }
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            InstructorAchievementsPage(
                page: page, flash: FlashMessages(success: notice?.text), hasActiveCourse: course != nil,
                courseCode: course?.code ?? "",
                signalOptions: AchievementSignalPresentation.all,
                recordDimensionOptions: RecordDimensionPresentation.all,
                targets: targets,
                earned: earned, builtIn: WardrobeItem.allCases.map(BuiltInRuleRow.init))
        }.encodeResponse(for: req)
    }

    // MARK: - Rows

    @Sendable
    func getCourseAchievements(req: Request) async throws -> PublishedAssignmentRoutes.AchievementsResponse {
        let user = try req.auth.require(APIUser.self)
        guard let course = try await activeCourse(req: req, user: user) else {
            throw WebAssignmentError.noActiveCourse(action: "reading course achievements")
        }
        return .init(achievements: AchievementsEditing.rows(fromCourse: course))
    }

    @Sendable
    func putCourseAchievements(req: Request) async throws -> PublishedAssignmentRoutes.AchievementsResponse {
        let user = try req.auth.require(APIUser.self)
        let course = try await req.requireActiveCourseForWrite(
            user, atLeast: .ta, action: "editing course achievements")
        let body = try await req.decodeContent(PublishedAssignmentRoutes.AchievementsBody.self)
        let rows = try await AchievementsEditing.apply(rows: body.achievements, course: course, on: req.db)
        return .init(achievements: rows)
    }

    // MARK: - Recompute

    /// Runs the course evaluator for every enrolled student (decision 7), so
    /// the ledger does not wait for each student's next page load. It is
    /// idempotent. It stores no assignment badge: only the student's own
    /// pages do, so `achievementsEarned` counts what those pages stored.
    @Sendable
    func recomputeCourseAchievements(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let course = try await req.requireActiveCourseForWrite(
            user, atLeast: .ta, action: "recomputing course achievements")
        // A failure for one student is logged and the rest go on, as on a
        // page load; the next Recompute or page load grants it again.
        for enrollment in try await CourseRoster.studentEnrollments(in: course.requireID(), on: req.db) {
            await AchievementAwardStore.grantCourseAchievementsOrLog(
                for: enrollment.userID, in: [course], on: req.db, logger: req.logger)
        }
        return req.redirect(to: "/instructor/achievements?notice=\(AchievementsNotice.recomputed.rawValue)")
    }

    // MARK: - Helpers

    private func activeCourse(req: Request, user: APIUser) async throws -> APICourse? {
        try await req.activeCourseRow(for: user)
    }

    /// The course's sections and assignments, in display order, for the
    /// course condition's "Counts over" control.
    private static func targetOptions(
        for course: APICourse, on db: any Database
    ) async throws -> CourseAchievementTargetOptions {
        let courseID = try course.requireID()
        let sections = try await APICourseSection.query(on: db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder)
            .all()
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
            .sorted { ($0.sortOrder ?? .max, $0.title) < ($1.sortOrder ?? .max, $1.title) }
        return CourseAchievementTargetOptions(
            sections: try sections.map { .init(id: try $0.requireID().uuidString, name: $0.name) },
            assignments: assignments.map { .init(publicID: $0.publicID, title: $0.title) },
            achievements: try await achievementChoices(of: assignments, on: db))
    }

    /// The individual achievements of the course's assignments, once each by
    /// id, for the `achievementsEarned` select. A built-in such as Ace has
    /// one id in every assignment, so it is listed once.
    private static func achievementChoices(
        of assignments: [APIAssignment], on db: any Database
    ) async throws -> [CourseAchievementTargetOptions.AchievementChoice] {
        let setupIDs = assignments.map(\.testSetupID)
        guard !setupIDs.isEmpty else { return [] }
        let setups = try await APITestSetup.query(on: db).filter(\.$id ~~ setupIDs).all()
        var seen = Set<String>()
        var choices: [CourseAchievementTargetOptions.AchievementChoice] = []
        for setup in setups {
            for row in AchievementsEditing.rows(fromManifest: setup.manifest)
            where row.scope == AchievementScope.individual.rawValue {
                guard let id = row.id, seen.insert(id).inserted else { continue }
                choices.append(.init(id: id, name: row.name))
            }
        }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Per course achievement, the enrolled students who have earned it,
    /// oldest award first. Course staff read their own course here, on the
    /// web; no MCP tool reports it.
    private static func earnedRows(
        for course: APICourse, on db: any Database
    ) async throws -> [CourseAchievementEarnedRow] {
        let definitions = course.courseAchievements
        guard !definitions.isEmpty else { return [] }
        let courseID = try course.requireID()
        let studentIDs = try await CourseRoster.studentIDs(in: courseID, on: db)
        let awards =
            studentIDs.isEmpty
            ? []
            : try await APIAchievementAward.query(on: db)
                .filter(\.$level == AchievementLevel.course.rawValue)
                .filter(\.$ownerID == courseID.uuidString)
                .filter(\.$userID ~~ Array(studentIDs))
                .sort(\.$earnedAt, .ascending)
                .all()
        let users = try await APIUser.query(on: db).filter(\.$id ~~ Array(Set(awards.map(\.userID)))).all()
        var names: [UUID: String] = [:]
        for user in users {
            guard let id = user.id else { continue }
            names[id] = accountIdentityName(
                displayName: user.displayName, preferredName: user.preferredName, username: user.username)
        }
        let formatter = waterlooDateTimeFormatter()
        return definitions.map { achievement in
            let earners = awards.filter { $0.achievementID == achievement.id }.map { award in
                CourseAchievementEarnedRow.Earner(
                    name: names[award.userID] ?? "Unknown student",
                    earnedText: award.earnedAt.map { formatter.string(from: $0) } ?? "")
            }
            return CourseAchievementEarnedRow(
                name: achievement.name, earners: earners,
                countText: "\(earners.count) of \(studentIDs.count) \(studentIDs.count == 1 ? "student" : "students")")
        }
    }
}
