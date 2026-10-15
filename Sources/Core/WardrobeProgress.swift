// Core/WardrobeProgress.swift
//
// What a student's own graded work shows, for the wardrobe unlock rules
// (Core/WardrobeItem.swift, #2592). Built from the student's submissions
// that have a result.

/// What a student's own graded work shows, for the unlock rules.
public struct WardrobeProgress: Equatable, Sendable {
    /// At least one of their submissions has a result.
    public var hasGradedSubmission: Bool
    /// A first attempt passed every test it ran.
    public var hasFirstTryFullMarks: Bool
    /// The number of different assignments with a submission that passed
    /// every test it ran.
    public var fullMarksAssignments: Int
    /// The concepts of the assignments with a submission that passed every
    /// test it ran. An assignment with no concept adds none.
    public var fullMarksConcepts: Set<AssignmentConcept>

    public init(
        hasGradedSubmission: Bool, hasFirstTryFullMarks: Bool, fullMarksAssignments: Int,
        fullMarksConcepts: Set<AssignmentConcept> = []
    ) {
        self.hasGradedSubmission = hasGradedSubmission
        self.hasFirstTryFullMarks = hasFirstTryFullMarks
        self.fullMarksAssignments = fullMarksAssignments
        self.fullMarksConcepts = fullMarksConcepts
    }

    /// One graded submission, as the rules read it.
    public struct Graded: Sendable {
        public let assignmentID: String
        public let attemptNumber: Int
        public let passCount: Int
        public let totalTests: Int
        /// The concept the instructor tagged the assignment with, if any.
        public let concept: AssignmentConcept?

        public init(
            assignmentID: String, attemptNumber: Int, passCount: Int, totalTests: Int,
            concept: AssignmentConcept? = nil
        ) {
            self.assignmentID = assignmentID
            self.attemptNumber = attemptNumber
            self.passCount = passCount
            self.totalTests = totalTests
            self.concept = concept
        }

        /// Every test it ran passed, and it ran at least one.
        public var isFullMarks: Bool { totalTests > 0 && passCount == totalTests }
    }

    /// The progress `graded` shows.
    public init(graded: [Graded]) {
        let fullMarks = graded.filter(\.isFullMarks)
        self.init(
            hasGradedSubmission: !graded.isEmpty,
            hasFirstTryFullMarks: fullMarks.contains { $0.attemptNumber == 1 },
            fullMarksAssignments: Set(fullMarks.map(\.assignmentID)).count,
            fullMarksConcepts: Set(fullMarks.compactMap(\.concept)))
    }
}
