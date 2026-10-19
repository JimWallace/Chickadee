// APIServer/Services/DatasetDeals.swift
//
// Deals the numbers behind the partition datasets and picks the number each
// delivery path uses (docs/datasets-course-library.md §4.11). The part of a
// partitioned file that a student receives is their number modulo the spec's
// part count (`DatasetSpec.part(forDeal:)`).
//
// A number is dealt the first time a delivery path needs it for a student,
// and does not change after that. The dealer takes the lowest number nobody
// holds, so the class fills the parts in turn, and a number freed by a
// deleted student is dealt again. On a class composite, the student's slot
// is the number, so a student's tile and their rows agree.
//
// Dealing is safe under a race: the unique keys on `dataset_deals` refuse a
// second row for a student and a second student for a number. A loser
// re-reads its own row, or tries the next free number. No insert runs inside
// a transaction: on Postgres a failed insert aborts the transaction.

import Core
import Fluent
import Foundation
import Vapor

enum DatasetDeals {

    /// The deal number for `userID`, dealing one if needed, or nil when the
    /// manifest has no partition or there is no student.
    ///
    /// Course staff and admins get 0 and are never dealt one: a dealt number
    /// is a student's, and a staff member's submission is stored as a student
    /// one.
    ///
    /// On a class composite the number is the student's slot, read and never
    /// dealt here: the composite deals its slots itself, on open and as the
    /// grading backstop, in the pool of the student's group
    /// (`CompositeSlots`). A grading path asks the composite for its inputs
    /// first, so the slot exists by then. A student with no slot yet gets
    /// nil: a grading path then grades the whole file, and a path that does
    /// not grade holds the partition back (`withholdingUndealtParts`).
    static func dealNumber(
        manifest: TestProperties, courseID: UUID, assignmentID: UUID?, userID: UUID?, on db: any Database
    ) async throws -> Int? {
        guard manifest.hasPartitionedDatasets, let assignmentID, let userID else { return nil }
        if let user = try await APIUser.find(userID, on: db), try await isCourseStaff(user, inCourse: courseID, db: db)
        {
            return 0
        }
        if manifest.activity?.kind == .classComposite {
            return try await CompositePool.dealtSlot(assignmentID: assignmentID, userID: userID, on: db)?.slot
        }
        return try await deal(assignmentID: assignmentID, userID: userID, on: db)
    }

    /// `files` with each partition cut to its header row while the student
    /// holds no part yet: a class composite deals the slot later, on open in
    /// the session window or when the first submission is graded. For the
    /// paths that do not grade (the editor copy, the "my rows" download), so
    /// a student never reads rows they will not be graded on. The editor
    /// copy's fingerprint folds in the deal number, so it is written again
    /// once the slot is dealt.
    static func withholdingUndealtParts(
        _ files: [String: String]?, manifest: TestProperties, dealNumber: Int?
    ) -> [String: String]? {
        guard var files, dealNumber == nil, manifest.activity?.kind == .classComposite else { return files }
        for spec in manifest.datasets where spec.kind == .partition {
            files[spec.file] = files[spec.file].map(DatasetMaterializer.headerOnly)
        }
        return files
    }

    /// The deal number of one grading job, by its kind: the slot it renders
    /// for a composite's reference job, `pinned` for a pinned run (a
    /// validation variant or a spare, from its materialization), 0 for a
    /// validation or a starter run, the student's number for a student's run,
    /// and nil for a job with no student (a class corpus run), which then
    /// grades the whole file.
    ///
    /// A reference job reads its slot, not its materialization: one
    /// materialization serves the reference jobs of every slot.
    static func jobDealNumber(
        manifest: TestProperties, courseID: UUID, assignmentID: UUID?, submission: APISubmission, pinned: Int?,
        on db: any Database
    ) async throws -> Int? {
        guard manifest.hasPartitionedDatasets else { return nil }
        if submission.kind == APISubmission.Kind.compositeReference, let submissionID = submission.id {
            return try await APICompositeReference.query(on: db).filter(\.$submissionID == submissionID).first()?.slot
        }
        if let pinned { return pinned }
        switch submission.kind {
        case APISubmission.Kind.validation, APISubmission.Kind.starterValidation:
            return 0
        case APISubmission.Kind.student:
            return try await dealNumber(
                manifest: manifest, courseID: courseID, assignmentID: assignmentID, userID: submission.userID,
                on: db)
        default:
            return nil
        }
    }

    /// The student's number, dealing the lowest free one if they have none.
    static func deal(assignmentID: UUID, userID: UUID, on db: any Database) async throws -> Int {
        if let existing = try await dealt(assignmentID: assignmentID, userID: userID, on: db) {
            return existing
        }
        var attempt = 0
        while true {
            let taken = Set(
                try await APIDatasetDeal.query(on: db)
                    .filter(\.$assignmentID == assignmentID)
                    .all()
                    .map(\.dealNumber))
            let next = (0...).first { !taken.contains($0) } ?? taken.count
            let row = APIDatasetDeal(assignmentID: assignmentID, userID: userID, dealNumber: next)
            do {
                try await row.create(on: db)
                return row.dealNumber
            } catch let error where isInsertConflict(error) && attempt < 8 {
                attempt += 1
                // A concurrent request may have dealt this student first.
                if let existing = try await dealt(assignmentID: assignmentID, userID: userID, on: db) {
                    return existing
                }
            }
        }
    }

    private static func dealt(assignmentID: UUID, userID: UUID, on db: any Database) async throws -> Int? {
        try await APIDatasetDeal.query(on: db)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$userID == userID)
            .first()?
            .dealNumber
    }
}
