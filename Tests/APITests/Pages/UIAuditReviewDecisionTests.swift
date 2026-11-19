// Tests/APITests/Pages/UIAuditReviewDecisionTests.swift
//
// Three review decisions on UI audit #3007: an admin's own row shows the role
// as a plain badge, not a disabled select (decision 2); a submission whose
// grading failed has the danger badge in the history tables (decision 3);
// and the empty Runners table explains itself in one sentence (decision 6).

import Elementary
import Testing

@testable import APIServer

@Suite struct UIAuditReviewDecisionTests {

    private func userRow(isCurrentUser: Bool) -> String {
        var row = AdminUserRow(
            id: "u1", displayName: "Ada", username: "ada", role: "admin", createdAt: "2026-10-01", lastSeenAt: nil)
        row.isCurrentUser = isCurrentUser
        return UserRow(user: row, csrfToken: "t").render()
    }

    @Test func yourOwnRowShowsTheRoleWithNoControl() {
        let html = userRow(isCurrentUser: true)
        #expect(html.contains(#"<span class="tier">Admin</span>"#))
        #expect(!html.contains("<select"))
        #expect(!html.contains("/admin/users/u1/role"))
    }

    @Test func anotherUsersRowKeepsTheRoleSelect() {
        let html = userRow(isCurrentUser: false)
        #expect(html.contains("<select"))
        #expect(html.contains("/admin/users/u1/role"))
        #expect(!html.contains("disabled"))
    }

    @Test(arguments: [
        (SubmissionStatus.pending, "tier"), (.assigned, "tier"), (.running, "tier"),
        (.complete, "tier"), (.failed, "tier tier-danger"), (.arena, "tier"),
    ])
    func onlyAFailedGradingRunIsADangerBadge(status: SubmissionStatus, badgeClass: String) {
        #expect(status.badgeClass == badgeClass)
        #expect(SubmissionStatus.badgeClass(forRaw: status.rawValue) == badgeClass)
    }

    @Test func anUnknownRawStatusIsNeutral() {
        #expect(SubmissionStatus.badgeClass(forRaw: "not-a-status") == "tier")
    }

    @Test func theEmptyRunnersTableExplainsItselfInOneSentence() {
        let html = WorkerRows(workers: []).render()
        #expect(html.contains("No runners are connected, so submissions wait in the queue."))
    }
}
