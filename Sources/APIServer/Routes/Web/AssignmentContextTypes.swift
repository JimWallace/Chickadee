// APIServer/Routes/Web/AssignmentContextTypes.swift
//
// View-context structs used as Leaf template data for assignment-related views.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Foundation

// MARK: - View context types

struct AssignmentRow: Encodable {
    let setupID:      String
    let assignmentID: String?   // nil if unpublished
    let title:        String?   // nil if unpublished
    let isOpen:       Bool?     // nil if unpublished
    let dueAt:        String?
    let status:       String    // "unpublished" | "open" | "closed"
    let sortOrder:    Int?
    let validationStatus: String
    let validationSubmissionID: String?
    let suiteCount:   Int
    let createdAt:    String
    let submittedStudentCount: Int?  // nil if unpublished; unique enrolled students who submitted at least once
}

/// A course section with its grouped assignment rows, used in instructor and student views.
struct CourseSectionRow: Encodable {
    let sectionID: String           // UUID as string
    let name: String
    let defaultGradingMode: String  // "browser" | "worker"
    let sortOrder: Int
    let rows: [AssignmentRow]       // assignments in this section, sorted
}

struct AssignmentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let sections: [CourseSectionRow]    // sections with their assignments
    let ungroupedRows: [AssignmentRow]  // assignments/setups not in any section
    let hasSections: Bool
    let hasUngrouped: Bool
    let enrolledStudents: [EnrolledStudentRow]
    let hasEnrolledStudents: Bool       // explicit flag — Leaf's array.isEmpty is unreliable
    let enrolledStudentCount: Int
    let courseEnrollmentMode: String
    let courseIsArchived: Bool
}

struct EnrolledStudentRow: Encodable {
    let id: String
    let username: String
    let displayName: String
    let role: String        // "student" | "instructor" | "admin"
}

struct AssignmentSubmissionsContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let rows: [AssignmentStudentRow]
}

struct AssignmentStudentRow: Encodable {
    let studentID: String
    let surname: String
    let givenNames: String
    let gradeText: String
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let fullHistoryURL: String
}

struct ValidateContext: Encodable {
    let currentUser:  CurrentUserContext?
    let assignmentID: String
    let setupID:      String
    let title:        String
    let suiteCount:   Int
    let dueAt:        String?
}

struct NewAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentName: String
    let dueAt: String
    let sections: [CourseSectionRow]    // available sections for the section picker
    let preselectedSectionID: String    // from ?sectionID= query param
    let notice: String?
    let error: String?
}

struct EditAssignmentContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let testSetupID: String
    let assignmentName: String
    let dueAt: String
    let currentAssignmentFile: String
    let currentAssignmentURL: String
    let assignmentNotebookEditURL: String
    let currentSolutionFile: String?
    let currentSolutionURL: String?
    let solutionNotebookEditURL: String?
    let existingSuiteRows: [EditableSuiteRow]
    let notice: String?
    let error: String?
}

struct CurrentFileLink {
    let name: String
    let url: String
}

struct EditableSuiteRow: Encodable {
    let name: String
    let url: String
    let isTest: Bool
    let tier: String
    let order: Int
    let dependsOn: [String]    // script names of prerequisites; empty == none
    let points: Int            // grade weight; 1 = default (unweighted)
    let displayName: String?   // optional human-readable name shown to students

    /// Empty string when displayName is nil — Leaf doesn't support `??` in templates.
    var displayNameOrEmpty: String { displayName ?? "" }

    /// Display name if set, otherwise the filename stem (extension stripped).
    /// Used as the default value of the name input in the assignment editor.
    var displayNameOrStem: String {
        if let n = displayName, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return n }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// JSON-encoded `dependsOn` array for use as an HTML data attribute in Leaf templates.
    var dependsOnJSON: String {
        let data = (try? JSONEncoder().encode(dependsOn)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case isTest
        case tier
        case order
        case dependsOn
        case points
        case displayName
        case displayNameOrEmpty
        case displayNameOrStem
        case dependsOnJSON
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isTest, forKey: .isTest)
        try container.encode(tier, forKey: .tier)
        try container.encode(order, forKey: .order)
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(displayNameOrEmpty, forKey: .displayNameOrEmpty)
        try container.encode(displayNameOrStem, forKey: .displayNameOrStem)
        try container.encode(dependsOnJSON, forKey: .dependsOnJSON)
    }
}

struct AssignmentStudentHistoryContext: Encodable {
    let currentUser: CurrentUserContext?
    let assignmentID: String
    let assignmentTitle: String
    let studentID: String
    let historyPath: String
    let rows: [AssignmentSubmissionHistoryRow]
}

struct AssignmentSubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
}
