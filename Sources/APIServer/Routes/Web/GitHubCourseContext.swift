// APIServer/Routes/Web/GitHubCourseContext.swift
//
// The view model of the instructor's course GitHub page
// (docs/github-submissions.md slice 4).

import Foundation

struct InstructorGitHubContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    /// Per-course instructors may change the page; TAs may only read it.
    let canEdit: Bool
    /// The bound organization, or nil.
    let organization: InstructorGitHubOrganization?
    /// Where an organization owner installs the App.
    let installURL: String
    /// The typed organization, kept after a refused bind.
    let organizationText: String
    /// Assignments that accept GitHub submission.
    let assignments: [InstructorGitHubAssignmentRow]
    /// True when the organization's template list could not be read.
    let templatesUnavailable: Bool
    /// Every course repository, for staff (slice 5 adds the last push).
    let repositories: [InstructorGitHubRepositoryRow]
    let flashSuccess: String?
    let flashError: String?
}

struct InstructorGitHubOrganization: Encodable {
    let login: String
    let url: String
    /// True when members may fork private repositories, so a student can make
    /// a copy outside the course's control.
    let forksAllowed: Bool
    /// True when the fork setting could not be read.
    let forksUnknown: Bool
}

struct InstructorGitHubAssignmentRow: Encodable {
    let testSetupID: String
    let title: String
    /// "None" first, then the organization's templates.
    let templateOptions: [GitHubSubmitOption]
    let templateName: String?
    let repositoryCount: Int
}

struct InstructorGitHubRepositoryRow: Encodable {
    let assignmentTitle: String
    let studentName: String
    let repositoryName: String
    let repositoryURL: String
    /// "Not reported" until a webhook reports a push.
    let lastPushedText: String
    /// The same moment as ISO-8601, for the relative-time label; nil before a push.
    let lastPushedISO: String?
    let archived: Bool
}
