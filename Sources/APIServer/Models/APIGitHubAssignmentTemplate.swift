// APIServer/Models/APIGitHubAssignmentTemplate.swift
//
// The template repository an assignment makes course repositories from
// (docs/github-submissions.md slice 4). At most one per test setup. A row
// here puts the assignment in course-repository mode: each student submits
// only from the repository made for them.

import Fluent
import Vapor

final class APIGitHubAssignmentTemplate: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "github_assignment_templates"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "template_repo_id")
    var templateRepoID: Int64

    /// `owner/name` when it was chosen, for display and for the generate call.
    @Field(key: "template_full_name")
    var templateFullName: String

    @Timestamp(key: "set_at", on: .create)
    var setAt: Date?

    init() {}

    init(testSetupID: String, templateRepoID: Int64, templateFullName: String) {
        self.testSetupID = testSetupID
        self.templateRepoID = templateRepoID
        self.templateFullName = templateFullName
    }
}
