// APIServer/Helpers/CourseSectionLookup.swift
//
// Section lookups shared by the course-admin routes, the new-assignment
// route and `NewAssignmentDraftService`: validate a posted section ID
// against a course, and read a section's default grading mode. Both were
// file-scope functions in route files until #2142; the service calls them,
// so they live below the routes.

import Core
import Fluent
import Foundation

/// Validates a sectionID string (UUID) against the given course and returns the UUID if valid.
/// Returns nil for absent, empty, or "none" values (meaning "ungrouped").
func resolveSectionID(_ raw: String?, courseID: UUID, db: Database) async throws -> UUID? {
    guard let raw, !raw.isEmpty, raw.lowercased() != "none" else { return nil }
    guard let uuid = UUID(uuidString: raw) else {
        throw WebAssignmentError.invalidParameter(name: "sectionID", reason: "Invalid sectionID format.")
    }
    guard let section = try await APICourseSection.find(uuid, on: db),
        section.courseID == courseID
    else {
        // Section not found or belongs to a different course — silently ignore.
        return nil
    }
    return uuid
}

/// Resolves the default grading mode for the section identified by
/// `sectionIDRaw` within `courseID`.  Falls back to `"worker"` when
/// the section can't be resolved (e.g., the form's "Ungrouped"
/// pseudo-section, or a missing section row).
func newAssignmentSectionGradingMode(
    courseID: UUID,
    sectionIDRaw: String,
    on db: any Database
) async throws -> String {
    guard let sid = try await resolveSectionID(sectionIDRaw, courseID: courseID, db: db),
        let sec = try await APICourseSection.find(sid, on: db)
    else {
        return "worker"
    }
    return sec.defaultGradingMode
}
