// APIServer/Models/APIGitHubCourseOrganization.swift
//
// The GitHub organization bound to a Chickadee course
// (docs/github-submissions.md slice 4). Course repositories are made in this
// organization, through the App's installation on it. At most one per course.
// The organization's numeric ID is the identity; the login is for display.

import Fluent
import Vapor

final class APIGitHubCourseOrganization: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "github_course_organizations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "course_id")
    var courseID: UUID

    /// The App's installation on the organization.
    @Field(key: "installation_id")
    var installationID: Int64

    @Field(key: "org_id")
    var orgID: Int64

    @Field(key: "org_login")
    var orgLogin: String

    @Timestamp(key: "bound_at", on: .create)
    var boundAt: Date?

    init() {}

    init(courseID: UUID, installationID: Int64, orgID: Int64, orgLogin: String) {
        self.courseID = courseID
        self.installationID = installationID
        self.orgID = orgID
        self.orgLogin = orgLogin
    }
}
