// Tests/APITests/TierFilterTests.swift
//
// Pure-logic coverage for the tier-visibility gates in TierFilter.swift.
// These pin the contract that release-tier visibility is gated on the
// *effective* (per-student, extension-aware) deadline rather than the bare
// assignment due date — the integration-level proof lives in
// SubmissionQueryRoutesTests / WebRoutesSubmissionPageTests.
//
// The gates take an `isStaff` bool (true = course staff / admin, false =
// student) since #417 Slice G moved staff resolution per-course to the caller.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct TierFilterTests {

    // MARK: - visibleTiers

    @Test func visibleTiersInstructorAlwaysSeesEveryTier() {
        let now = Date()
        // Deadline far in the future — staff still see all three tiers.
        let tiers = visibleTiers(
            isStaff: true, effectiveDueAt: now.addingTimeInterval(86_400), now: now)
        #expect(tiers == ["public", "release", "secret"])
    }

    @Test func visibleTiersStudentHidesReleaseBeforeEffectiveDeadline() {
        let now = Date()
        let tiers = visibleTiers(
            isStaff: false, effectiveDueAt: now.addingTimeInterval(3600), now: now)
        #expect(tiers == ["public"])
    }

    @Test func visibleTiersStudentShowsReleaseAfterEffectiveDeadline() {
        let now = Date()
        let tiers = visibleTiers(
            isStaff: false, effectiveDueAt: now.addingTimeInterval(-3600), now: now)
        #expect(tiers == ["public", "release"])
    }

    @Test func visibleTiersStudentShowsReleaseWhenNoDeadline() {
        // nil effective deadline → no deadline → release immediately visible.
        let tiers = visibleTiers(isStaff: false, effectiveDueAt: nil)
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
        let tiers = visibleTiers(isStaff: false, effectiveDueAt: extended, now: now)
        #expect(tiers == ["public"], "release stays hidden until the student's own deadline passes")
    }

    // MARK: - releaseOutputVisible

    @Test func releaseOutputInstructorAlwaysVisible() {
        let now = Date()
        #expect(
            releaseOutputVisible(
                isStaff: true, effectiveDueAt: now.addingTimeInterval(86_400), now: now))
    }

    @Test func releaseOutputStudentHiddenBeforeEffectiveDeadline() {
        let now = Date()
        #expect(
            releaseOutputVisible(
                isStaff: false, effectiveDueAt: now.addingTimeInterval(3600), now: now) == false)
    }

    @Test func releaseOutputStudentVisibleAfterEffectiveDeadline() {
        let now = Date()
        #expect(
            releaseOutputVisible(
                isStaff: false, effectiveDueAt: now.addingTimeInterval(-3600), now: now))
    }

    @Test func releaseOutputStudentVisibleWhenNoDeadline() {
        #expect(releaseOutputVisible(isStaff: false, effectiveDueAt: nil))
    }

    @Test func releaseOutputStudentHiddenWhileExtensionActive() {
        let now = Date()
        let extended = now.addingTimeInterval(86_400)
        #expect(
            releaseOutputVisible(isStaff: false, effectiveDueAt: extended, now: now) == false,
            "an active extension keeps release output redacted past the class deadline")
    }
}
