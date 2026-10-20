// APIServer/Services/AchievementsEditing+Course.swift
//
// The course source for `AchievementsEditing` (docs/achievement-rewards.md,
// slice S3). A course's achievements live on the course row
// (`APICourse.courseAchievements`) in the same shape as a manifest's, so the
// row conversion and the validator are the assignment editor's, at the
// course level. The web tab (S4) and the MCP tools (S5) call `apply`.

import Core
import Fluent
import Foundation

/// What a course achievement's targets may name: the course's sections and
/// the assignments students can count.
struct CourseAchievementContext: Sendable {
    /// Course section id (uppercase UUID string) by section name.
    let sectionIDsByName: [String: String]
    let sectionIDs: Set<String>
    /// Public ID of every assignment in the course.
    let assignmentPublicIDs: Set<String>

    init(sections: [(id: String, name: String)], assignmentPublicIDs: Set<String>) {
        var byName: [String: String] = [:]
        for section in sections where byName[section.name] == nil {
            byName[section.name] = section.id
        }
        sectionIDsByName = byName
        sectionIDs = Set(sections.map(\.id))
        self.assignmentPublicIDs = assignmentPublicIDs
    }

    /// The context of `course`, read from the database.
    static func of(_ course: APICourse, on db: any Database) async throws -> CourseAchievementContext {
        let courseID = try course.requireID()
        let sections = try await APICourseSection.query(on: db).filter(\.$courseID == courseID).all()
        let assignments = try await APIAssignment.query(on: db).filter(\.$courseID == courseID).all()
        return CourseAchievementContext(
            sections: try sections.map { (try $0.requireID().uuidString, $0.name) },
            assignmentPublicIDs: Set(assignments.map(\.publicID)))
    }
}

extension AchievementsEditing {

    // MARK: - Course rows

    /// The rows the course editor shows: the course's achievements as stored.
    /// There are no built-in course defaults to merge in.
    static func rows(fromCourse course: APICourse) -> [AchievementRow] {
        course.courseAchievements.map(row(from:))
    }

    /// Replaces the course's achievements wholesale with these rows, after
    /// each is validated at the course level and every target is checked
    /// against the course. Returns the reconciled rows. A course achievement
    /// changes no grade, so nothing is retested.
    @discardableResult
    static func apply(rows: [AchievementRow], course: APICourse, on db: any Database) async throws -> [AchievementRow] {
        let context = try await CourseAchievementContext.of(course, on: db)
        let achievements = try rows.map { try achievement(from: $0, at: .course) }
        let resolved = try validate(achievements, againstCourse: context)
        course.courseAchievements = resolved
        try await course.save(on: db)
        return Self.rows(fromCourse: course)
    }

    /// Checks a course's achievements against the course, and returns them
    /// with each target in its stored form: a section named by its id, and an
    /// assignment list without blanks. Ids must be unique, and every target
    /// must name something the course has, or the rule would count nothing.
    static func validate(
        _ achievements: [Achievement], againstCourse context: CourseAchievementContext
    ) throws -> [Achievement] {
        var seen = Set<String>()
        return try achievements.map { achievement in
            guard seen.insert(achievement.id).inserted else {
                throw WebAssignmentError.invalidParameter(
                    name: "id", reason: "Duplicate achievement id '\(achievement.id)'.")
            }
            let conditions = try achievement.conditions.map { condition in
                guard let target = condition.target else { return condition }
                return AchievementCondition(
                    signal: condition.signal, comparator: condition.comparator, value: condition.value,
                    target: try resolved(target, in: context, for: achievement.name),
                    gradeFloor: condition.gradeFloor, achievementRef: condition.achievementRef)
            }
            return Achievement(
                id: achievement.id, name: achievement.name, detail: achievement.detail,
                scope: achievement.scope, conditions: conditions, match: achievement.match,
                reward: achievement.reward, classFraction: achievement.classFraction,
                recordDimension: achievement.recordDimension)
        }
    }

    /// `target` with its ref checked against the course and normalized.
    private static func resolved(
        _ target: AchievementTarget, in context: CourseAchievementContext, for name: String
    ) throws -> AchievementTarget {
        let ref = target.ref ?? ""
        switch target.kind {
        case .courseSection:
            // An MCP agent can read a section's name but not always its id,
            // so a name resolves to the id, as suite section refs do.
            let id = UUID(uuidString: ref)?.uuidString ?? ref
            if context.sectionIDs.contains(id) { return AchievementTarget(kind: .courseSection, ref: id) }
            if let byName = context.sectionIDsByName[ref] {
                return AchievementTarget(kind: .courseSection, ref: byName)
            }
            throw WebAssignmentError.invalidParameter(
                name: "targetRef", reason: "'\(name)' counts course section '\(ref)', which this course does not have.")
        case .concept:
            guard AssignmentConcept(rawValue: ref) != nil else {
                throw WebAssignmentError.invalidParameter(
                    name: "targetRef",
                    reason: "'\(name)' counts concept '\(ref)', which is not a concept. Use one of "
                        + AssignmentConcept.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            return target
        case .assignments:
            let ids = CourseProgress.publicIDs(in: ref)
            guard !ids.isEmpty else {
                throw WebAssignmentError.invalidParameter(
                    name: "targetRef", reason: "'\(name)' counts a list of assignments that names none.")
            }
            if let missing = ids.first(where: { !context.assignmentPublicIDs.contains($0) }) {
                throw WebAssignmentError.invalidParameter(
                    name: "targetRef",
                    reason: "'\(name)' counts assignment '\(missing)', which this course does not have.")
            }
            return AchievementTarget(kind: .assignments, ref: ids.joined(separator: ","))
        case .assignmentGrade, .suiteItem, .section, .testPass:
            throw WebAssignmentError.invalidParameter(
                name: "targetKind",
                reason: "'\(name)' counts over a '\(target.kind.rawValue)', which names no set of assignments.")
        }
    }

    // MARK: - Course conditions

    /// A course achievement (docs/achievement-rewards.md, S3): an individual
    /// badge with at least one course condition. A class goal or a record at
    /// the course level is a later slice, so it is refused here rather than
    /// saved as a rule nothing evaluates.
    static func courseAchievement(
        id: String, name: String, detail: String?, scope: AchievementScope, match: ConditionMatch,
        conditions: [AchievementCondition]
    ) throws -> Achievement {
        guard scope == .individual else {
            throw WebAssignmentError.invalidParameter(
                name: "scope",
                reason: "'\(name)': a course achievement is awarded to one student. Use the "
                    + "'individual' scope.")
        }
        guard !conditions.isEmpty else {
            throw WebAssignmentError.invalidParameter(
                name: "conditions",
                reason: "'\(name)' has no conditions. A course achievement needs at least one, or "
                    + "every student would earn it at once.")
        }
        return Achievement(
            id: id, name: name, detail: detail, scope: .individual, conditions: conditions, match: match,
            reward: AchievementReward(type: .badge, label: name))
    }

    /// One course condition. A count only grows, and an award is kept once it
    /// is earned, so the only comparator that means the same thing on every
    /// page load is 'at least', and the count must be at least one.
    static func courseCondition(
        signal: AchievementSignal, comparator: ConditionComparator, from input: ConditionRow
    ) throws -> AchievementCondition {
        guard comparator == .atLeast else {
            throw WebAssignmentError.invalidParameter(
                name: "comparator",
                reason: "'\(signal.rawValue)' is a count that only grows, so it takes 'atLeast' only.")
        }
        let value = input.value ?? 0
        guard value >= 1, value == value.rounded() else {
            throw WebAssignmentError.invalidParameter(
                name: "value", reason: "'\(signal.rawValue)' needs a whole number of at least 1.")
        }
        var gradeFloor: Double?
        if signal == .assignmentsAtGrade {
            guard let floor = input.gradeFloor, (0...100).contains(floor) else {
                throw WebAssignmentError.invalidParameter(
                    name: "gradeFloor", reason: "'assignmentsAtGrade' needs a grade floor of 0–100%.")
            }
            gradeFloor = floor
        }
        let ref = (input.achievementRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let achievementRef = signal == .achievementsEarned && !ref.isEmpty ? ref : nil
        return AchievementCondition(
            signal: signal, comparator: .atLeast, value: value, target: try courseTarget(from: input),
            gradeFloor: gradeFloor, achievementRef: achievementRef)
    }

    /// The set of assignments a course condition counts over, or nil for every
    /// assignment in the course. The ref is checked against the course in
    /// `validate(_:againstCourse:)`.
    static func courseTarget(from input: ConditionRow) throws -> AchievementTarget? {
        let raw = (input.targetKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let kind = TargetKind(rawValue: raw), kind.namesCourseAssignments else {
            let kinds = TargetKind.allCases.filter(\.namesCourseAssignments).map(\.rawValue)
            throw WebAssignmentError.invalidParameter(
                name: "targetKind",
                reason: "Unknown set of assignments '\(raw)'. Use one of " + kinds.joined(separator: ", ")
                    + ", or none for every assignment in the course.")
        }
        let ref = (input.targetRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
            throw WebAssignmentError.invalidParameter(
                name: "targetRef", reason: "A '\(kind.rawValue)' set needs a reference.")
        }
        return AchievementTarget(kind: kind, ref: ref)
    }

}
