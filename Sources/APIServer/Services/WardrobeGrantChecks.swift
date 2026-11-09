// APIServer/Services/WardrobeGrantChecks.swift
//
// Lets the result page skip the wardrobe grant when nothing that the grant
// reads has changed (docs/database-performance.md).
//
// The grant reads every graded student submission the student has made, in
// every course and term, and runs on every load of the student's own result
// page: 16% of that page's CPU at one course's scale, growing each term. What
// the student has earned changes only when a new result arrives, or when an
// assignment's due date or concept changes. So the page first reads a
// fingerprint of both, one aggregate row, and runs the grant only when the
// fingerprint differs from the last complete grant in this process.
//
// A fingerprint is recorded only after a grant that stored everything earned,
// so a failed write grants again on the next load. A process starts with no
// fingerprints, so each student's first load after a deploy runs the grant.
// The account page always runs the full grant (`grantEarned`).

import Foundation
import Vapor

actor WardrobeGrantChecks {
    /// The fingerprint of each student's results at their last complete grant.
    private var lastComplete: [UUID: WardrobeGradedFingerprint] = [:]
    /// A bound on the map: it is cleared when it reaches this size, which
    /// costs only one extra grant per student.
    private let capacity: Int

    init(capacity: Int = 50_000) {
        self.capacity = capacity
    }

    /// True when `fingerprint` equals the one recorded for `userID`.
    func isUnchanged(_ userID: UUID, _ fingerprint: WardrobeGradedFingerprint) -> Bool {
        lastComplete[userID] == fingerprint
    }

    /// Records a complete grant at `fingerprint`.
    func recordComplete(_ userID: UUID, _ fingerprint: WardrobeGradedFingerprint) {
        if lastComplete.count >= capacity, lastComplete[userID] == nil { lastComplete.removeAll() }
        lastComplete[userID] = fingerprint
    }
}

/// What the wardrobe grant reads for one student, in brief: the count of
/// their graded student-submission results, the newest receipt time among
/// them, and a hash of the due date and concept of each assignment they
/// submitted to (`WardrobeUnlockStore.gradedFingerprint`). A new result, or a
/// due-date or concept edit, changes it.
struct WardrobeGradedFingerprint: Equatable, Sendable {
    let count: Int
    let latest: Date?
    let assignments: String?
}

struct WardrobeGrantChecksKey: StorageKey {
    typealias Value = WardrobeGrantChecks
}

extension Application {
    var wardrobeGrantChecks: WardrobeGrantChecks {
        lazyStored(WardrobeGrantChecksKey.self) { WardrobeGrantChecks() }
    }
}
