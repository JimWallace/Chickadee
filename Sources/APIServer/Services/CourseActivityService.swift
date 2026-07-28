// APIServer/Services/CourseActivityService.swift
//
// The merged course activity timeline (#421): who changed what in this course,
// and when.
//
// Two records feed it, because two different things happened and neither alone
// answers the question a lead instructor is actually asking:
//
//   - `assignment_versions` — every content edit, from the browser or an agent,
//     with the actor and what produced it. Rich, but content-only by design.
//   - `audit_log` — the events content versioning deliberately does not cover:
//     staff added/removed/re-roled, and the assignment lifecycle (created,
//     cloned, deleted, visibility, due date). Deletion in particular leaves no
//     version row behind, so this is the only trace it ever existed.
//
// They are merged rather than shown side by side because the question is
// chronological — "what happened to this course last Tuesday" — and two lists
// would leave the reader correlating timestamps by eye.

import Fluent
import Foundation
import Vapor

/// One row of the timeline, already formatted for display.
struct CourseActivityRow: Encodable, Sendable {
    let timestamp: String
    let actor: String
    /// Coarse grouping shown as a chip: "Content edit" or the audit category.
    let category: String
    /// What happened, in one line.
    let summary: String
    /// What it happened to (assignment title, or a person for staff events).
    let target: String
    /// Extra context — the version number, the origin, the changed value.
    let detail: String
    /// Where to go to see it, when there is somewhere sensible.
    let link: String?
}

enum CourseActivityService {

    /// How many events one page of the timeline shows. Deliberately modest: the
    /// view answers "what changed recently", and an agent authoring session can
    /// produce hundreds of content versions in an afternoon.
    static let defaultLimit = 100

    /// Builds the merged timeline for `courseID`, newest first.
    ///
    /// `actorFilter` matches an actor username substring; nil shows everyone.
    static func timeline(
        courseID: UUID,
        actorFilter: String? = nil,
        limit: Int = defaultLimit,
        on db: any Database
    ) async throws -> [CourseActivityRow] {
        // Over-fetch each source by the page size: after the merge only the
        // newest `limit` survive, and either source could supply all of them.
        async let versionsFetch = contentEdits(
            courseID: courseID, actorFilter: actorFilter, limit: limit, on: db)
        async let eventsFetch = courseEvents(
            courseID: courseID, actorFilter: actorFilter, limit: limit, on: db)

        let (versions, events) = try await (versionsFetch, eventsFetch)
        let merged = (versions + events)
            .sorted { $0.sortKey > $1.sortKey }
            .prefix(limit)

        let formatter = waterlooDateTimeFormatter()
        return merged.map { entry in
            CourseActivityRow(
                timestamp: formatter.string(from: entry.sortKey),
                actor: entry.actor,
                category: entry.category,
                summary: entry.summary,
                target: entry.target,
                detail: entry.detail,
                link: entry.link)
        }
    }

    /// A row before formatting, carrying the real `Date` so the two sources can
    /// be merged on one comparable key.
    private struct Entry {
        let sortKey: Date
        let actor: String
        let category: String
        let summary: String
        let target: String
        let detail: String
        let link: String?
    }

    // MARK: - Content edits

    private static func contentEdits(
        courseID: UUID, actorFilter: String?, limit: Int, on db: any Database
    ) async throws -> [Entry] {
        var query = APIAssignmentVersion.query(on: db)
            .filter(\.$courseID == courseID)
        if let actorFilter {
            query = query.filter(\.$actorUsername ~~ actorFilter)
        }
        let versions =
            try await query
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
        guard !versions.isEmpty else { return [] }

        // Resolve titles in one query rather than per row.
        let assignmentIDs = Set(versions.compactMap(\.assignmentID))
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$id ~~ Array(assignmentIDs))
            .all()
        var titleByID: [UUID: (title: String, publicID: String)] = [:]
        for assignment in assignments where assignment.id != nil {
            titleByID[assignment.id ?? UUID()] = (assignment.title, assignment.publicID)
        }

        return versions.compactMap { version in
            guard let createdAt = version.createdAt else { return nil }
            let assignment = version.assignmentID.flatMap { titleByID[$0] }
            return Entry(
                sortKey: createdAt,
                // A baseline or a clone seed has no human behind it — say so
                // rather than showing an empty column.
                actor: version.actorUsername ?? "system",
                category: "Content edit",
                summary: summaryForVersion(version),
                target: assignment?.title ?? "(deleted assignment)",
                detail: "v\(version.versionNumber) · \(version.origin)",
                link: assignment.map { "/instructor/\($0.publicID)/edit" })
        }
    }

    /// One line describing what a version represents. The `origin` already
    /// encodes the surface and the action (`mcp:update_suite`,
    /// `web:PUT /instructor/:assignmentID/suite`), so this turns it into
    /// something readable without inventing detail the row does not have.
    private static func summaryForVersion(_ version: APIAssignmentVersion) -> String {
        if let summary = version.summary, !summary.isEmpty { return summary }
        if let restoredFrom = version.restoredFromVersion {
            return "Restored version \(restoredFrom)"
        }
        switch version.origin {
        case AssignmentVersionOrigin.baseline:
            return "Baseline captured before first recorded edit"
        case AssignmentVersionOrigin.clone:
            return "Content copied from another assignment"
        case AssignmentVersionOrigin.create:
            return "Initial content"
        case AssignmentVersionOrigin.bundleImport:
            return "Content imported from a course bundle"
        default:
            break
        }
        if version.origin.hasPrefix("mcp:") {
            return "Edited by an agent (\(version.origin.dropFirst(4)))"
        }
        if version.origin.hasPrefix("web:") {
            return "Edited in the browser"
        }
        return "Content changed"
    }

    // MARK: - Course events

    private static func courseEvents(
        courseID: UUID, actorFilter: String?, limit: Int, on db: any Database
    ) async throws -> [Entry] {
        var query = APIAuditLogEntry.query(on: db)
            .filter(\.$courseID == courseID)
        if let actorFilter {
            query = query.filter(\.$actorUsername ~~ actorFilter)
        }
        let entries =
            try await query
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()

        return entries.compactMap { entry in
            guard let createdAt = entry.createdAt else { return nil }
            let display = AuditActionDisplay.categoryLabel(forRaw: entry.action)
            let metadata = decodedMetadata(entry.metadata)
            return Entry(
                sortKey: createdAt,
                actor: entry.actorUsername ?? "system",
                category: display.category,
                summary: display.label,
                target: metadata["assignment"] ?? metadata["title"]
                    ?? metadata["subject_user_id"] ?? entry.targetID ?? "—",
                detail: detailLine(metadata),
                link: metadata["assignment"].map { "/instructor/\($0)/edit" })
        }
    }

    /// The metadata keys worth showing, in a fixed order so the column reads
    /// consistently. Everything else (ids, internal source markers) stays out —
    /// the full blob is on `/admin/audit` for anyone who needs it.
    private static func detailLine(_ metadata: [String: String]) -> String {
        let interesting = ["visibility", "role", "current", "previous", "source_assignment"]
        let parts = interesting.compactMap { key -> String? in
            guard let value = metadata[key], !value.isEmpty else { return nil }
            return "\(key): \(value)"
        }
        return parts.joined(separator: " · ")
    }

    private static func decodedMetadata(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }
}
