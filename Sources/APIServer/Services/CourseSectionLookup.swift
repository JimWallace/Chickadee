// APIServer/Services/CourseSectionLookup.swift
//
// Section lookups shared by the course-admin routes, the new-assignment
// route and `NewAssignmentDraftService`: validate a posted section ID
// against a course, and resolve the type a new assignment declares. Both were
// file-scope functions in route files until #2142; the service calls them,
// so they live below the routes.

import Core
import Fluent
import Foundation

/// Validates a sectionID string (UUID) against the given course and returns the UUID if valid.
/// Returns nil for absent, empty, or "none" values (meaning "ungrouped").
func resolveSectionID(_ raw: String?, courseID: UUID, db: any Database) async throws -> UUID? {
    guard let raw, !raw.isEmpty, raw.lowercased() != "none" else { return nil }
    guard let uuid = UUID(uuidString: raw) else {
        throw AppError.invalidParameter(name: "sectionID", reason: "Invalid sectionID format.")
    }
    guard let section = try await APICourseSection.find(uuid, on: db),
        section.courseID == courseID
    else {
        // Section not found or belongs to a different course — silently ignore.
        return nil
    }
    return uuid
}

/// The type a new assignment declares on the create page: the type the author
/// chose, else the default type of the section it goes into, else Assignment,
/// the type whose secret tests stay on the worker (docs/assignment-types.md).
/// An empty `requestedRaw` means no choice; an unknown one is refused.
func newAssignmentDeclaredType(
    requestedRaw: String?,
    courseID: UUID,
    sectionIDRaw: String,
    on db: any Database
) async throws -> AssignmentType {
    let requested = requestedRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !requested.isEmpty {
        guard let type = AssignmentType(rawValue: requested) else {
            throw AppError.invalidParameter(
                name: "assignmentType",
                reason: "Unknown assignment type \"\(requested)\". Known types: "
                    + AssignmentType.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return type
    }
    guard let sid = try await resolveSectionID(sectionIDRaw, courseID: courseID, db: db),
        let section = try await APICourseSection.find(sid, on: db)
    else {
        return .assignment
    }
    return section.defaultAssignmentType ?? .assignment
}
