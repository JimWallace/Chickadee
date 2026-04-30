// APIServer/Routes/Web/AssignmentSlugHelpers.swift
//
// Public-ID and per-course slug allocation for assignments.  Extracted
// from AssignmentHelpers.swift (issue #442) — no behaviour changes.

import Vapor
import Fluent
import Core
import Foundation

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
    throw Abort(.internalServerError, reason: "Unable to allocate assignment URL slug")
}

func isValidAssignmentPublicID(_ value: String) -> Bool {
    value.count == APIAssignment.publicIDLength
        && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

func assignmentPublicIDParameter(from req: Request) throws -> String {
    guard let raw = req.parameters.get("assignmentID"), isValidAssignmentPublicID(raw) else {
        throw Abort(.notFound)
    }
    return raw
}

func createAssignmentWithUniquePublicID(
    req: Request,
    testSetupID: String,
    title: String,
    dueAt: Date?,
    isOpen: Bool,
    sortOrder: Int?,
    validationStatus: String? = nil,
    validationSubmissionID: String? = nil,
    sectionID: UUID? = nil,
    courseID: UUID
) async throws -> APIAssignment {
    for _ in 0..<32 {
        let candidate = APIAssignment.generatePublicID()
        let exists = try await APIAssignment.query(on: req.db)
            .filter(\.$publicID == candidate)
            .count() > 0
        if exists { continue }

        let assignment = APIAssignment(
            publicID: candidate,
            testSetupID: testSetupID,
            title: title,
            slug: try await uniqueAssignmentSlug(title: title, courseID: courseID, db: req.db),
            dueAt: dueAt,
            isOpen: isOpen,
            sortOrder: sortOrder,
            validationStatus: validationStatus,
            validationSubmissionID: validationSubmissionID,
            sectionID: sectionID,
            courseID: courseID
        )
        do {
            try await assignment.save(on: req.db)
        } catch {
            let conflict = try await APIAssignment.query(on: req.db)
                .filter(\.$publicID == candidate)
                .count() > 0
            if conflict { continue }
            throw error
        }
        return assignment
    }

    throw Abort(.internalServerError, reason: "Unable to allocate assignment URL id")
}
