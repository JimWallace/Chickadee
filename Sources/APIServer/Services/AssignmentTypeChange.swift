// APIServer/Services/AssignmentTypeChange.swift
//
// The declared assignment type's write path and the lookup the manifest
// writers use to check it (docs/assignment-types.md, phase 2). The web Type
// select and MCP `update_assignment` both change the type here, so the rule
// check and the audit record cannot differ between them.

import Core
import Fluent
import Foundation

/// The type the assignment on `setup` declares, or nil when the setup has
/// no assignment row yet (a draft) or the row stores no type
/// (`APIAssignment.declaredAssignmentType`). Every manifest writer that can change
/// the grading mode or the activity passes this to `ManifestCoherence`, so
/// the type cannot drift from the manifest after creation.
func declaredAssignmentType(of setup: APITestSetup, on db: any Database) async throws -> AssignmentType? {
    guard let setupID = setup.id else { return nil }
    return try await assignmentByTestSetupID(setupID, on: db)?.declaredAssignmentType
}

/// Why a type change was refused.
enum AssignmentTypeChangeError: Error, Equatable {
    /// The new type breaks a rule on the current manifest; the message is
    /// `ManifestCoherence`'s.
    case breaksRule(String)

    var message: String {
        switch self {
        case .breaksRule(let message): message
        }
    }
}

enum AssignmentTypeChange {
    /// Declares `next` on `assignment` and writes one audit record. A no-op
    /// when the type is unchanged. Refused when the new type breaks a rule
    /// the current type does not (`ManifestCoherence.violation(declaring:)`),
    /// so a Class activity with no activity may still become an Assignment.
    /// The type is a column: no manifest change, no regrade.
    static func apply(
        _ next: AssignmentType, to assignment: APIAssignment, via: String,
        on db: any Database, audit: some AuditContext
    ) async throws {
        let previous = assignment.declaredAssignmentType
        guard next != previous else { return }
        let setup = try await APITestSetup.find(assignment.testSetupID, on: db)
        if let violation = ManifestCoherence.violation(declaring: next, over: previous, in: setup?.manifest) {
            throw AssignmentTypeChangeError.breaksRule(violation)
        }
        assignment.assignmentType = next
        try await assignment.save(on: db)
        await AuditLogger.recordAssignmentLifecycle(
            .assignmentTypeChanged, assignment: assignment,
            metadata: ["previous": previous?.rawValue ?? "none", "current": next.rawValue, "via": via],
            on: audit)
    }
}
