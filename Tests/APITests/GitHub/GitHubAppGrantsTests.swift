// Tests/APITests/GitHub/GitHubAppGrantsTests.swift
//
// The rule that turns the permissions and events GitHub reports into the
// App's three options (#1776). The pages that show them are covered by
// `GitHubAppGrantsPageTests`.

import Foundation
import Testing

@testable import APIServer

@Suite struct GitHubAppGrantsTests {
    /// The check reads the manifest's own permission constants, so an App made
    /// with every option on must pass it.
    @Test func whatTheManifestAsksForGrantsEveryOption() throws {
        let manifest = try #require(
            GitHubAppManifest(
                publicBaseURL: URL(string: "https://courses.example.edu"), organization: nil,
                courseRepositories: true, pushEvents: true, commitStatuses: true))
        let grants = GitHubAppGrants(permissions: manifest.permissions, events: ["push"])
        #expect(grants.missing.isEmpty)
    }

    @Test func theSlice3MinimumGrantsNoOption() {
        let grants = GitHubAppGrants(permissions: GitHubAppManifest.submissionPermissions, events: [])
        #expect(grants.missing == [.courseRepositories, .pushEvents, .commitStatuses])
    }

    @Test func aHigherLevelCoversALowerOne() {
        let grants = GitHubAppGrants(
            permissions: ["administration": "admin", "members": "write", "statuses": "write"], events: [])
        #expect(grants.allows(.courseRepositories))
        #expect(grants.allows(.commitStatuses))
    }

    @Test func aLowerLevelDoesNotCoverAHigherOne() {
        let grants = GitHubAppGrants(
            permissions: ["administration": "read", "members": "read", "statuses": "read"], events: [])
        #expect(!grants.allows(.courseRepositories))
        #expect(!grants.allows(.commitStatuses))
    }

    @Test func courseRepositoriesNeedBothPermissions() {
        #expect(!GitHubAppGrants(permissions: ["administration": "write"], events: []).allows(.courseRepositories))
        #expect(!GitHubAppGrants(permissions: ["members": "read"], events: []).allows(.courseRepositories))
    }

    @Test func anUnknownLevelGrantsNothing() {
        #expect(!GitHubAppGrants(permissions: ["statuses": "none"], events: []).allows(.commitStatuses))
    }

    @Test func pushEventsNeedThePushEventAndNoPermission() {
        #expect(GitHubAppGrants(permissions: [:], events: ["installation", "push"]).allows(.pushEvents))
        #expect(!GitHubAppGrants(permissions: [:], events: ["pull_request"]).allows(.pushEvents))
    }

    @Test func rowsFollowTheDisplayOrder() {
        let rows = GitHubCapabilityRow.rows(for: GitHubAppGrants(permissions: ["statuses": "write"], events: []))
        #expect(
            rows == [
                GitHubCapabilityRow(label: "Course repositories", granted: false),
                GitHubCapabilityRow(label: "Push events", granted: false),
                GitHubCapabilityRow(label: "Commit statuses", granted: true),
            ])
    }
}
