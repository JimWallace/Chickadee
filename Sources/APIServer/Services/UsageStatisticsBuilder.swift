// APIServer/Services/UsageStatisticsBuilder.swift
//
// Builds a `UsageReport`: how much Chickadee was used across a set of academic
// terms, for annual reporting. The admin MCP tool `get_usage_summary` is its
// caller.
//
// A report is scoped by term, not by date: a course counts in the term it is
// offered in, and everything in that course (its enrollments, assignments and
// submissions) counts with it. A course that records no term is placed by the
// date it was created, and its row says so.
//
// The counting happens in the database: submissions and lab openings are
// grouped per course and per user, so the builder reads one row per student
// per course rather than one per submission. User IDs are read only to count
// distinct people; none reaches the report (`UsageReport`).

import Core
import Fluent
import Foundation
import SQLKit

/// What a usage report covers.
struct UsageReportRequest: Sendable {
    /// The terms to count. Duplicates are ignored; the report lists them
    /// oldest first.
    let terms: [AcademicTerm]
    /// When set, only courses where this user holds an instructor enrollment.
    let instructorUserID: UUID?
    /// When set, only courses whose code or key (`CS136`, `CS136-F26`) is in
    /// the list, compared case-insensitively.
    let courseKeys: [String]?
    /// Whether the report carries one row per course.
    let includePerCourse: Bool
}

enum UsageStatisticsError: Error, Equatable {
    /// The counts are SQL aggregates; a non-SQL database cannot answer them.
    case requiresSQLDatabase
}

enum UsageStatisticsBuilder {
    static func report(
        _ request: UsageReportRequest, on db: any Database, now: Date = Date()
    ) async throws -> UsageReport {
        guard let sql = db as? (any SQLDatabase) else { throw UsageStatisticsError.requiresSQLDatabase }
        let terms = Array(Set(request.terms)).sorted()
        var facts = try await placedCourses(request, terms: Set(terms), on: db)
        let courseIDs = Array(facts.keys)
        if !courseIDs.isEmpty {
            try await addEnrollments(to: &facts, courseIDs: courseIDs, on: db)
            try await addAssignments(to: &facts, courseIDs: courseIDs, on: db)
            try await addSubmissions(to: &facts, courseIDs: courseIDs, sql: sql)
            try await addLabParticipations(to: &facts, courseIDs: courseIDs, sql: sql)
            try await addCourseCounts(to: &facts, courseIDs: courseIDs, sql: sql)
        }

        let courses = facts.values.sorted {
            ($0.term, $0.code.lowercased(), $0.key) < ($1.term, $1.code.lowercased(), $1.key)
        }
        let byTerm = terms.map { term in
            UsageTermBreakdown(
                term: term.shortLabel, termName: term.displayName,
                totals: UsageTotals(folding: courses.filter { $0.term == term }))
        }
        return UsageReport(
            generatedAt: now,
            terms: terms.map(\.shortLabel),
            totals: UsageTotals(folding: courses),
            integrations: UsageIntegrations(folding: courses),
            byTerm: byTerm,
            perCourse: request.includePerCourse ? courses.map(\.row) : nil,
            notes: notes(inferredTerms: courses.count(where: \.termInferred)))
    }

    /// The term a course counts in: its recorded term, else the term its
    /// creation date falls in on the Waterloo calendar. Nil when it has
    /// neither.
    static func placement(of course: APICourse) -> (term: AcademicTerm, inferred: Bool)? {
        if let term = course.term { return (term, false) }
        guard let created = course.createdAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        let parts = calendar.dateComponents([.year, .month], from: created)
        guard let year = parts.year, let month = parts.month,
            let term = AcademicTerm(year: year, season: TermSeason.containing(month: month))
        else { return nil }
        return (term, true)
    }

    // MARK: - Courses

    /// Every course (archived included: past offerings are what a report is
    /// about) placed in one of `terms` and passing the request's filters.
    private static func placedCourses(
        _ request: UsageReportRequest, terms: Set<AcademicTerm>, on db: any Database
    ) async throws -> [UUID: UsageCourseFacts] {
        var instructed: Set<UUID>?
        if let userID = request.instructorUserID {
            instructed = Set(
                try await APICourseEnrollment.query(on: db)
                    .filter(\.$userID == userID)
                    .filter(\.$roleRaw == CourseRole.instructor.rawValue)
                    .all()
                    .map(\.$course.id))
        }
        let keys = request.courseKeys.map { Set($0.map { $0.lowercased() }) }
        var facts: [UUID: UsageCourseFacts] = [:]
        for course in try await APICourse.query(on: db).all() {
            guard let id = course.id, let placed = placement(of: course), terms.contains(placed.term) else {
                continue
            }
            if let instructed, !instructed.contains(id) { continue }
            if let keys, !keys.contains(course.code.lowercased()), !keys.contains(course.urlKey.lowercased()) {
                continue
            }
            facts[id] = UsageCourseFacts(
                courseID: id, code: course.code, key: course.urlKey, name: course.name,
                term: placed.term, termInferred: placed.inferred, archived: course.isArchived,
                usesBrightSpace: course.brightspaceOrgUnitID != nil,
                usesLTI: course.ltiPlatformID != nil,
                usesAIFeedback: course.aiFeedbackEnabled == true)
        }
        return facts
    }

    // MARK: - People

    private static func addEnrollments(
        to facts: inout [UUID: UsageCourseFacts], courseIDs: [UUID], on db: any Database
    ) async throws {
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id ~~ courseIDs)
            .all()
        for enrollment in enrollments {
            let courseID = enrollment.$course.id
            switch enrollment.role {
            case .student: facts[courseID]?.students.insert(enrollment.userID)
            case .ta: facts[courseID]?.teachingAssistants.insert(enrollment.userID)
            case .instructor: facts[courseID]?.instructors.insert(enrollment.userID)
            }
        }
    }

    // MARK: - Assignments

    private static func addAssignments(
        to facts: inout [UUID: UsageCourseFacts], courseIDs: [UUID], on db: any Database
    ) async throws {
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID ~~ courseIDs)
            .all()
        let setupIDs = Array(Set(assignments.map(\.testSetupID)))
        var languageBySetup: [String: String] = [:]
        if !setupIDs.isEmpty {
            for setup in try await APITestSetup.query(on: db).filter(\.$id ~~ setupIDs).all() {
                guard let id = setup.id else { continue }
                languageBySetup[id] = languageKey(setup.decodedManifest())
            }
        }
        for assignment in assignments {
            let courseID = assignment.courseID
            facts[courseID]?.assignments += 1
            facts[courseID]?.assignmentsByType[assignment.assignmentType.rawValue, default: 0] += 1
            let language = languageBySetup[assignment.testSetupID] ?? "undeclared"
            facts[courseID]?.assignmentsByLanguage[language, default: 0] += 1
        }
    }

    /// The language an assignment declares: its language, "none" for a
    /// declared no-language suite, or "undeclared".
    private static func languageKey(_ manifest: TestProperties?) -> String {
        if let language = manifest?.language { return language.rawValue }
        return manifest?.languageDeclared == true ? "none" : "undeclared"
    }

    // MARK: - Submissions and labs

    private struct SubmissionGroup: Decodable {
        let courseID: UUID
        let userID: UUID?
        let kind: String
        let status: String
        let sourceKind: String?
        let n: Int
        enum CodingKeys: String, CodingKey {
            case courseID = "course_id"
            case userID = "user_id"
            case kind, status
            case sourceKind = "source_kind"
            case n
        }
    }

    private static func addSubmissions(
        to facts: inout [UUID: UsageCourseFacts], courseIDs: [UUID], sql: any SQLDatabase
    ) async throws {
        let kinds = [APISubmission.Kind.student, APISubmission.Kind.validation]
        let rows = try await sql.raw(
            """
            SELECT t.course_id AS course_id, s.user_id AS user_id, s.kind AS kind,
                s.status AS status, s.source_kind AS source_kind, COUNT(*) AS n
            FROM \(unsafeRaw: APISubmission.schema) s
            INNER JOIN \(unsafeRaw: APITestSetup.schema) t ON t.id = s.test_setup_id
            WHERE t.course_id IN (\(binds: courseIDs))
              AND s.kind IN (\(binds: kinds))
            GROUP BY t.course_id, s.user_id, s.kind, s.status, s.source_kind
            """
        ).all(decoding: SubmissionGroup.self)
        for row in rows {
            guard row.kind == APISubmission.Kind.student else {
                facts[row.courseID]?.validationSubmissions += row.n
                continue
            }
            facts[row.courseID]?.studentSubmissions += row.n
            facts[row.courseID]?.studentByStatus[row.status, default: 0] += row.n
            let source = row.sourceKind ?? SubmissionSource.upload.rawValue
            facts[row.courseID]?.studentBySource[source, default: 0] += row.n
            if let userID = row.userID {
                facts[row.courseID]?.participants.insert(userID)
                facts[row.courseID]?.studentSubmissionsByUser[userID, default: 0] += row.n
            }
        }
    }

    private struct ParticipationGroup: Decodable {
        let courseID: UUID
        let userID: UUID
        let n: Int
        enum CodingKeys: String, CodingKey {
            case courseID = "course_id"
            case userID = "user_id"
            case n
        }
    }

    private static func addLabParticipations(
        to facts: inout [UUID: UsageCourseFacts], courseIDs: [UUID], sql: any SQLDatabase
    ) async throws {
        let rows = try await sql.raw(
            """
            SELECT a.course_id AS course_id, p.user_id AS user_id, COUNT(*) AS n
            FROM \(unsafeRaw: APIAssignmentParticipation.schema) p
            INNER JOIN \(unsafeRaw: APIAssignment.schema) a ON a.id = p.assignment_id
            WHERE a.course_id IN (\(binds: courseIDs))
            GROUP BY a.course_id, p.user_id
            """
        ).all(decoding: ParticipationGroup.self)
        for row in rows {
            facts[row.courseID]?.labParticipations += row.n
            facts[row.courseID]?.participants.insert(row.userID)
        }
    }

    // MARK: - Content, feedback, tournaments

    private struct CourseCount: Decodable {
        let courseID: UUID
        let n: Int
        enum CodingKeys: String, CodingKey {
            case courseID = "course_id"
            case n
        }
    }

    private static func addCourseCounts(
        to facts: inout [UUID: UsageCourseFacts], courseIDs: [UUID], sql: any SQLDatabase
    ) async throws {
        let content = try await sql.raw(
            """
            SELECT course_id, COUNT(*) AS n FROM \(unsafeRaw: APICourseContentItem.schema)
            WHERE course_id IN (\(binds: courseIDs))
            GROUP BY course_id
            """
        ).all(decoding: CourseCount.self)
        for row in content { facts[row.courseID]?.contentItems = row.n }

        let feedback = try await sql.raw(
            """
            SELECT a.course_id AS course_id, COUNT(*) AS n
            FROM \(unsafeRaw: APIReflectionFeedback.schema) f
            INNER JOIN \(unsafeRaw: APIAssignment.schema) a ON a.id = f.assignment_id
            WHERE a.course_id IN (\(binds: courseIDs)) AND f.released_at IS NOT NULL
            GROUP BY a.course_id
            """
        ).all(decoding: CourseCount.self)
        for row in feedback { facts[row.courseID]?.aiFeedbackReleased = row.n }

        let tournaments = try await sql.raw(
            """
            SELECT t.course_id AS course_id, COUNT(*) AS n
            FROM \(unsafeRaw: APITournamentRun.schema) r
            INNER JOIN \(unsafeRaw: APITestSetup.schema) t ON t.id = r.test_setup_id
            WHERE t.course_id IN (\(binds: courseIDs))
            GROUP BY t.course_id
            """
        ).all(decoding: CourseCount.self)
        for row in tournaments { facts[row.courseID]?.tournamentsRun = row.n }
    }

    // MARK: - Notes

    private static func notes(inferredTerms: Int) -> [String] {
        var notes = [
            "Courses count in the term they are offered in; their enrollments, assignments and "
                + "submissions count with them, whatever the date.",
            "Active students made at least one student submission or opened at least one "
                + "browser-graded lab. Course staff are never counted as students.",
            "Courses permanently deleted under the retention policy are gone from the database "
                + "and are not counted. Archived courses are counted.",
            "Validation runs are instructor checks of their own assignments, not student work.",
            "Per-course student counts below \(UsageReport.smallCourseThreshold) are withheld "
                + "(smallCourse); the totals include them.",
        ]
        if inferredTerms > 0 {
            notes.append(
                "\(inferredTerms) course(s) record no term and were placed by the date they were "
                    + "created (termInferred).")
        }
        return notes
    }
}
