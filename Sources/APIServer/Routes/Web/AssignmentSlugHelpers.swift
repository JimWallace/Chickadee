// APIServer/Routes/Web/AssignmentSlugHelpers.swift
//
// Public-ID and per-course slug allocation for assignments.  Extracted
// from AssignmentHelpers.swift (issue #442) — no behaviour changes.

import Core
import Fluent
import Foundation
import Vapor

func assignmentByPublicID(_ publicID: String, on db: Database) async throws -> APIAssignment? {
    try await APIAssignment.query(on: db)
        .filter(\.$publicID == publicID)
        .first()
}

func uniqueAssignmentSlug(
    title: String,
    courseID: UUID,
    excludingAssignmentID: UUID? = nil,
    db: Database,
    reserved: Set<String> = []
) async throws -> String {
    let base = VanityURLRoutes.slugify(title).isEmpty ? "assignment" : VanityURLRoutes.slugify(title)
    for suffix in 0..<10_000 {
        let candidate = suffix == 0 ? base : "\(base)-\(suffix + 1)"
        if reserved.contains(candidate) { continue }

        var query = APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .filter(\.$slug == candidate)
        if let excludingAssignmentID {
            query = query.filter(\.$id != excludingAssignmentID)
        }
        let exists = try await query.count() > 0
        if !exists { return candidate }
    }
    throw WebAssignmentError.internalFailure(reason: "Unable to allocate assignment URL slug")
}

func isValidAssignmentPublicID(_ value: String) -> Bool {
    value.count == APIAssignment.publicIDLength
        && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

func assignmentPublicIDParameter(from req: Request) throws -> String {
    guard let raw = req.parameters.get("assignmentID"), isValidAssignmentPublicID(raw) else {
        throw WebAssignmentError.notFound(resource: "Assignment")
    }
    return raw
}

// Mirrors the column-set on APIAssignment that publish / import flows
// need to set independently; bundling these into a struct would duplicate
// the model's own initializer surface without removing any names.  All
// call sites use labelled args so the long list reads cleanly.
// swiftlint:disable:next function_parameter_count
func createAssignmentWithUniquePublicID(
    on db: Database,
    testSetupID: String,
    title: String,
    dueAt: Date?,
    startsAt: Date? = nil,
    isOpen: Bool,
    sortOrder: Int?,
    validationStatus: String? = nil,
    validationSubmissionID: String? = nil,
    sectionID: UUID? = nil,
    courseID: UUID
) async throws -> APIAssignment {
    for _ in 0..<32 {
        let candidate = APIAssignment.generatePublicID()
        let exists =
            try await APIAssignment.query(on: db)
            .filter(\.$publicID == candidate)
            .count() > 0
        if exists { continue }

        let assignment = APIAssignment(
            publicID: candidate,
            testSetupID: testSetupID,
            title: title,
            slug: try await uniqueAssignmentSlug(title: title, courseID: courseID, db: db),
            dueAt: dueAt,
            startsAt: startsAt,
            isOpen: isOpen,
            sortOrder: sortOrder,
            validationStatus: validationStatus,
            validationSubmissionID: validationSubmissionID,
            sectionID: sectionID,
            courseID: courseID
        )
        do {
            try await assignment.save(on: db)
        } catch {
            let conflict =
                try await APIAssignment.query(on: db)
                .filter(\.$publicID == candidate)
                .count() > 0
            if conflict { continue }
            throw error
        }
        return assignment
    }

    throw WebAssignmentError.internalFailure(reason: "Unable to allocate assignment URL id")
}
