// Tests/APITests/TierFilterTests.swift
//
// Pure-logic coverage for the tier-visibility gates in TierFilter.swift.
// These pin the contract that release-tier visibility is gated on the
// *effective* (per-student, extension-aware) deadline rather than the bare
// assignment due date — the integration-level proof lives in
// SubmissionQueryRoutesTests / WebRoutesSubmissionPageTests.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct TierFilterTests {

    private func student() -> APIUser {
        APIUser(username: "s", passwordHash: "x", role: UserRole.student.rawValue)
    }

    private func instructor() -> APIUser {
        APIUser(username: "i", passwordHash: "x", role: UserRole.instructor.rawValue)
    }

    // MARK: - visibleTiers

    @Test func visibleTiersInstructorAlwaysSeesEveryTier() {
        let now = Date()
        // Deadline far in the future — an instructor still sees all three tiers.
        let tiers = visibleTiers(
            for: instructor(), effectiveDueAt: now.addingTimeInterval(86_400), now: now)
        #expect(tiers == ["public", "release", "secret"])
    }

    @Test func visibleTiersStudentHidesReleaseBeforeEffectiveDeadline() {
        let now = Date()
        let tiers = visibleTiers(
            for: student(), effectiveDueAt: now.addingTimeInterval(3600), now: now)
        #expect(tiers == ["public"])
    }

    @Test func visibleTiersStudentShowsReleaseAfterEffectiveDeadline() {
        let now = Date()
        let tiers = visibleTiers(
            for: student(), effectiveDueAt: now.addingTimeInterval(-3600), now: now)
        #expect(tiers == ["public", "release"])
    }

    @Test func visibleTiersStudentShowsReleaseWhenNoDeadline() {
        // nil effective deadline → no deadline → release immediately visible.
        let tiers = visibleTiers(for: student(), effectiveDueAt: nil)
        #expect(tiers == ["public", "release"])
    }

    /// The crux of the extension intersection: when the class deadline has
    /// passed but the student's effective (extended) deadline has not, release
    /// stays hidden.  The caller supplies the *effective* deadline, so the gate
    /// only has to compare against it.
    @Test func visibleTiersStudentHidesReleaseWhileExtensionActive() {
        let now = Date()
        // Effective deadline = the student's future extension, not the past
        // class-wide due date.
        let extended = now.addingTimeInterval(86_400)
        let tiers = visibleTiers(for: student(), effectiveDueAt: extended, now: now)
        #expect(tiers == ["public"], "release stays hidden until the student's own deadline passes")
    }

    // MARK: - releaseOutputVisible

    @Test func releaseOutputInstructorAlwaysVisible() {
        let now = Date()
        #expect(
            releaseOutputVisible(
                for: instructor(), effectiveDueAt: now.addingTimeInterval(86_400), now: now))
    }

    @Test func releaseOutputStudentHiddenBeforeEffectiveDeadline() {
        let now = Date()
        #expect(
            releaseOutputVisible(
                for: student(), effectiveDueAt: now.addingTimeInterval(3600), now: now) == false)
    }

    @Test func releaseOutputStudentVisibleAfterEffectiveDeadline() {
        let now = Date()
        #expect(
            releaseOutputVisible(
                for: student(), effectiveDueAt: now.addingTimeInterval(-3600), now: now))
    }

    @Test func releaseOutputStudentVisibleWhenNoDeadline() {
        #expect(releaseOutputVisible(for: student(), effectiveDueAt: nil))
    }

    @Test func releaseOutputStudentHiddenWhileExtensionActive() {
        let now = Date()
        let extended = now.addingTimeInterval(86_400)
        #expect(
            releaseOutputVisible(for: student(), effectiveDueAt: extended, now: now) == false,
            "an active extension keeps release output redacted past the class deadline")
    }
}
