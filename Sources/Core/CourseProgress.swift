// Core/CourseProgress.swift
//
// What a student's graded work in one course shows, for the course
// achievement signals (docs/achievement-rewards.md, decision 3). It is
// `WardrobeProgress` scoped to a set of assignments: the counts are the same
// arithmetic, taken over the assignments a condition's target names.

import Foundation

/// What a student's graded work in one course shows, for the course signals.
public struct CourseProgress: Sendable {

    /// One assignment students can see, with the facts a target selects it by.
    public struct Assignment: Equatable, Sendable {
        public let testSetupID: String
        public let publicID: String
        /// The course section the assignment is in, if any.
        public let courseSectionID: String?
        /// The concept the instructor tagged the assignment with, if any.
        public let concept: AssignmentConcept?

        public init(
            testSetupID: String, publicID: String, courseSectionID: String? = nil,
            concept: AssignmentConcept? = nil
        ) {
            self.testSetupID = testSetupID
            self.publicID = publicID
            self.courseSectionID = courseSectionID
            self.concept = concept
        }
    }

    /// One assignment-level award in the student's ledger.
    public struct Award: Equatable, Sendable {
        public let testSetupID: String
        public let achievementID: String

        public init(testSetupID: String, achievementID: String) {
            self.testSetupID = testSetupID
            self.achievementID = achievementID
        }
    }

    /// The assignments students can see. A draft or hidden assignment is not
    /// here, so it is in no count.
    public let assignments: [Assignment]
    /// The student's graded submissions. A submission to an assignment that
    /// is not in `assignments` counts for nothing.
    public let graded: [WardrobeProgress.Graded]
    /// The student's assignment-level awards.
    public let awards: [Award]

    public init(assignments: [Assignment], graded: [WardrobeProgress.Graded], awards: [Award] = []) {
        self.assignments = assignments
        self.graded = graded
        self.awards = awards
    }

    /// The assignments `target` names: every assignment for no target, or
    /// the ones in a course section, tagged with a concept, or listed by
    /// public ID. nil for a target that names no set of assignments, so a
    /// condition that carries one is unmet.
    public func assignments(in target: AchievementTarget?) -> [Assignment]? {
        guard let target else { return assignments }
        let ref = target.ref ?? ""
        switch target.kind {
        case .courseSection:
            return assignments.filter { $0.courseSectionID == ref }
        case .concept:
            guard let concept = AssignmentConcept(rawValue: ref) else { return nil }
            return assignments.filter { $0.concept == concept }
        case .assignments:
            let listed = Set(Self.publicIDs(in: ref))
            return assignments.filter { listed.contains($0.publicID) }
        case .assignmentGrade, .suiteItem, .section, .testPass:
            return nil
        }
    }

    /// The public IDs in an `assignments` target's ref, in order, with the
    /// blanks dropped.
    public static func publicIDs(in ref: String) -> [String] {
        ref.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The number `condition`'s course signal counts, or nil when the
    /// condition is not a course signal or cannot be counted as authored.
    public func count(for condition: AchievementCondition) -> Int? {
        guard condition.signal.readsTheCourse, let scoped = assignments(in: condition.target) else { return nil }
        let ids = Set(scoped.map(\.testSetupID))
        let inScope = graded.filter { ids.contains($0.assignmentID) }
        let progress = WardrobeProgress(graded: inScope)
        switch condition.signal {
        case .assignmentsGraded:
            return Set(inScope.map(\.assignmentID)).count
        case .assignmentsAtGrade:
            guard let floor = condition.gradeFloor else { return nil }
            let reached = inScope.filter { $0.gradePercent.map { Double($0) >= floor } ?? false }
            return Set(reached.map(\.assignmentID)).count
        case .assignmentsFullMarks:
            return progress.fullMarksAssignments
        case .assignmentsEarly:
            return progress.earlyAssignments
        case .assignmentsComeback:
            return progress.comebackAssignments
        case .achievementsEarned:
            return awards.filter { award in
                ids.contains(award.testSetupID)
                    && (condition.achievementRef.map { $0 == award.achievementID } ?? true)
            }.count
        case .conceptsAtFullMarks:
            return progress.fullMarksConcepts.count
        case .grade, .attempts, .executionTimeMs, .gradeJumpPercent, .testPass, .itemsCovered,
            .standing, .matchesWon, .classCoverage:
            return nil
        }
    }
}
