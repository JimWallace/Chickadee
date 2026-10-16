// Core/WardrobeProgress.swift
//
// What a student's own graded work shows, for the wardrobe unlock rules
// (Core/WardrobeItem.swift, #2592, docs/student-wardrobe.md E4). Built from
// the student's submissions that have a result.

/// What a student's own graded work shows, for the unlock rules.
public struct WardrobeProgress: Equatable, Sendable {
    /// At least one of their submissions has a result.
    public var hasGradedSubmission: Bool
    /// A first attempt passed every test it ran.
    public var hasFirstTryFullMarks: Bool
    /// The number of different assignments with a submission that passed
    /// every test it ran.
    public var fullMarksAssignments: Int
    /// The number of different assignments with a graded submission made at
    /// least `earlyLeadSeconds` before the due date. An assignment with no
    /// due date counts for none.
    public var earlyAssignments: Int
    /// The number of different assignments with a comeback: a submission
    /// that passed every test it ran, after an earlier attempt that did not.
    public var comebackAssignments: Int
    /// The concepts of the assignments with a submission that passed every
    /// test it ran. An assignment with no concept adds none.
    public var fullMarksConcepts: Set<AssignmentConcept>

    /// How long before the due date a submission counts as early: two days.
    public static let earlyLeadSeconds: Double = 48 * 60 * 60

    public init(
        hasGradedSubmission: Bool, hasFirstTryFullMarks: Bool, fullMarksAssignments: Int,
        earlyAssignments: Int = 0, comebackAssignments: Int = 0, fullMarksConcepts: Set<AssignmentConcept> = []
    ) {
        self.hasGradedSubmission = hasGradedSubmission
        self.hasFirstTryFullMarks = hasFirstTryFullMarks
        self.fullMarksAssignments = fullMarksAssignments
        self.earlyAssignments = earlyAssignments
        self.comebackAssignments = comebackAssignments
        self.fullMarksConcepts = fullMarksConcepts
    }

    /// One graded submission, as the rules read it.
    public struct Graded: Sendable {
        public let assignmentID: String
        public let attemptNumber: Int
        public let passCount: Int
        public let totalTests: Int
        /// How long before the assignment's due date the server received
        /// it, in seconds; negative when late, nil when the assignment has
        /// no due date.
        public let secondsBeforeDue: Double?
        /// The concept the instructor tagged the assignment with, if any.
        public let concept: AssignmentConcept?

        public init(
            assignmentID: String, attemptNumber: Int, passCount: Int, totalTests: Int,
            secondsBeforeDue: Double? = nil, concept: AssignmentConcept? = nil
        ) {
            self.assignmentID = assignmentID
            self.attemptNumber = attemptNumber
            self.passCount = passCount
            self.totalTests = totalTests
            self.secondsBeforeDue = secondsBeforeDue
            self.concept = concept
        }

        /// Every test it ran passed, and it ran at least one.
        public var isFullMarks: Bool { totalTests > 0 && passCount == totalTests }

        /// It arrived at least `earlyLeadSeconds` before the due date.
        public var isEarly: Bool { (secondsBeforeDue ?? -1) >= WardrobeProgress.earlyLeadSeconds }
    }

    /// The progress `graded` shows.
    public init(graded: [Graded]) {
        let fullMarks = graded.filter(\.isFullMarks)
        let comebacks = fullMarks.filter { success in
            graded.contains {
                $0.assignmentID == success.assignmentID && $0.attemptNumber < success.attemptNumber
                    && !$0.isFullMarks
            }
        }
        self.init(
            hasGradedSubmission: !graded.isEmpty,
            hasFirstTryFullMarks: fullMarks.contains { $0.attemptNumber == 1 },
            fullMarksAssignments: Set(fullMarks.map(\.assignmentID)).count,
            earlyAssignments: Set(graded.filter(\.isEarly).map(\.assignmentID)).count,
            comebackAssignments: Set(comebacks.map(\.assignmentID)).count,
            fullMarksConcepts: Set(fullMarks.compactMap(\.concept)))
    }
}
