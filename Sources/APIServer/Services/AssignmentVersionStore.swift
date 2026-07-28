// APIServer/Services/AssignmentVersionStore.swift
//
// The single entry point for recording an assignment content snapshot
// (docs/assignment-versioning.md). Every capture point — the web save paths and
// the MCP write tools alike — goes through `record` / `ensureBaseline` so the
// dedupe, numbering, and draft rules are written down exactly once.
//
// Two properties make the capture points cheap to wire:
//
//   - `record` is SELF-DEDUPING. It captures the setup's current state and
//     returns `.unchanged` when that state matches the newest version. So a
//     save that changed nothing costs one hash and no row, and a call site may
//     be generous: over-calling is free, under-calling is the only real failure
//     mode.
//   - `ensureBaseline` is a no-op once any version exists. Called before a
//     mutation, it makes the pre-edit state recoverable; after the first one it
//     is a single indexed count.
//
// Snapshots record the POST-edit state, so version N always names a state that
// actually existed and the newest version always equals current content. That
// is what makes "restore to N" unambiguous.

import Core
import Fluent
import Foundation
import Vapor

/// What produced a version. Free-form on the wire; these factories keep the
/// vocabulary consistent across call sites.
enum AssignmentVersionOrigin {
    /// The pre-edit state captured lazily on a setup with no history yet.
    static let baseline = "baseline"
    /// Seeded at creation by clone / copy-course.
    static let clone = "clone"
    /// Seeded at creation by a from-scratch assignment.
    static let create = "create"
    /// Seeded at creation by `.chickadee` bundle import.
    static let bundleImport = "import"

    /// An edit made through an MCP tool, e.g. `mcp:update_suite`.
    static func mcp(tool: String) -> String { "mcp:\(tool)" }
    /// An edit made through the web UI, e.g. `web:save_edit`.
    static func web(action: String) -> String { "web:\(action)" }
    /// A restore of version `version`.
    static func restore(of version: Int) -> String { "restore:\(version)" }
}

/// Everything about a snapshot that isn't the content itself. Bundled so the
/// entry points stay within the parameter budget, the same reason
/// `GlobalInputsService.Inputs` exists.
struct AssignmentVersionRequest: Sendable {
    let origin: String
    let summary: String?
    let restoredFromVersion: Int?
    let actorUserID: UUID?
    let actorUsername: String?

    init(
        origin: String,
        summary: String? = nil,
        restoredFromVersion: Int? = nil,
        actor: APIUser? = nil
    ) {
        self.origin = origin
        self.summary = summary
        self.restoredFromVersion = restoredFromVersion
        self.actorUserID = actor?.id
        self.actorUsername = actor?.username
    }
}

/// Why a snapshot wasn't taken. Both reasons are ordinary, not failures.
enum AssignmentVersionSkipReason: String, Sendable {
    /// The setup has no published assignment — a hidden authoring draft, whose
    /// edits aren't yet anyone's content.
    case draft
    /// `ensureBaseline` found existing history, so there is nothing to seed.
    case historyExists
}

enum AssignmentVersionOutcome: Sendable, Equatable {
    case recorded(version: Int)
    /// Content matched the newest version; no row written.
    case unchanged(version: Int)
    case skipped(reason: AssignmentVersionSkipReason)

    /// The version number this outcome refers to, if any.
    var version: Int? {
        switch self {
        case .recorded(let version), .unchanged(let version): return version
        case .skipped: return nil
        }
    }

    var didRecord: Bool {
        if case .recorded = self { return true }
        return false
    }
}

enum AssignmentVersionStore {

    /// Records `setup`'s CURRENT content as the next version.
    ///
    /// Call AFTER the edit has persisted. Returns `.unchanged` when the content
    /// matches the newest version, and `.skipped(.draft)` for a setup with no
    /// published assignment.
    @discardableResult
    static func record(
        setup: APITestSetup,
        request: AssignmentVersionRequest,
        testSetupsDirectory: String,
        on db: any Database
    ) async throws -> AssignmentVersionOutcome {
        guard let setupID = setup.id else { return .skipped(reason: .draft) }
        guard let assignment = try await publishedAssignment(setupID: setupID, on: db) else {
            return .skipped(reason: .draft)
        }

        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: testSetupsDirectory)
        let snapshot = try await AssignmentVersionSnapshotBuilder.build(
            setup: setup, blobs: blobs)

        if let newest = try await newestVersion(setupID: setupID, on: db),
            newest.snapshotHash == snapshot.snapshotHash
        {
            return .unchanged(version: newest.versionNumber)
        }

        let version = try await insert(
            snapshot: snapshot, setupID: setupID, assignment: assignment,
            courseID: setup.courseID, request: request, on: db)
        return .recorded(version: version)
    }

    /// Records `setup`'s current content as version 1 iff it has no history yet.
    ///
    /// Call BEFORE mutating, so the pre-edit state is recoverable. Without this,
    /// the first edit on every assignment that predates versioning is precisely
    /// the one that can't be undone — and seeding it lazily avoids a migration
    /// that would have to walk and hash every setup on disk at deploy time.
    @discardableResult
    static func ensureBaseline(
        setup: APITestSetup,
        testSetupsDirectory: String,
        on db: any Database
    ) async throws -> AssignmentVersionOutcome {
        guard let setupID = setup.id else { return .skipped(reason: .draft) }
        let existing = try await APIAssignmentVersion.query(on: db)
            .filter(\.$testSetupID == setupID)
            .count()
        guard existing == 0 else { return .skipped(reason: .historyExists) }

        return try await record(
            setup: setup,
            request: AssignmentVersionRequest(origin: AssignmentVersionOrigin.baseline),
            testSetupsDirectory: testSetupsDirectory,
            on: db)
    }

    /// Best-effort wrapper for call sites where a versioning failure must not
    /// fail the edit itself. The content change has already persisted by the
    /// time this runs; losing a history row is bad, losing the instructor's
    /// save because history couldn't be written is worse.
    @discardableResult
    static func recordBestEffort(
        setup: APITestSetup,
        request: AssignmentVersionRequest,
        testSetupsDirectory: String,
        logger: Logger,
        on db: any Database
    ) async -> AssignmentVersionOutcome? {
        do {
            return try await record(
                setup: setup, request: request, testSetupsDirectory: testSetupsDirectory, on: db)
        } catch {
            logger.warning(
                "assignment version snapshot failed",
                metadata: [
                    "setup": .string(setup.id ?? "?"),
                    "origin": .string(request.origin),
                    "error": .string("\(error)"),
                ])
            return nil
        }
    }

    // MARK: - Queries

    /// The newest version for a setup, or nil when it has no history.
    static func newestVersion(
        setupID: String, on db: any Database
    ) async throws -> APIAssignmentVersion? {
        try await APIAssignmentVersion.query(on: db)
            .filter(\.$testSetupID == setupID)
            .sort(\.$versionNumber, .descending)
            .first()
    }

    /// The published assignment for a setup, or nil for a hidden draft.
    private static func publishedAssignment(
        setupID: String, on db: any Database
    ) async throws -> APIAssignment? {
        try await APIAssignment.query(on: db)
            .filter(\.$testSetupID == setupID)
            .first()
    }

    // MARK: - Insert

    /// Maximum attempts to claim a version number. Two concurrent edits on one
    /// setup can compute the same next number; the unique index on
    /// `(test_setup_id, version_number)` turns that into an insert conflict,
    /// and re-reading the max resolves it — the same discipline as
    /// `createAssignmentWithUniquePublicID`.
    private static let numberingAttempts = 5

    private static func insert(
        snapshot: AssignmentVersionSnapshot,
        setupID: String,
        assignment: APIAssignment,
        courseID: UUID,
        request: AssignmentVersionRequest,
        on db: any Database
    ) async throws -> Int {
        var lastError: (any Error)?
        for _ in 0..<numberingAttempts {
            let next = (try await newestVersion(setupID: setupID, on: db)?.versionNumber ?? 0) + 1
            let row = APIAssignmentVersion(
                testSetupID: setupID,
                assignmentID: assignment.id,
                courseID: courseID,
                versionNumber: next,
                snapshot: snapshot,
                actorUserID: request.actorUserID,
                actorUsername: request.actorUsername,
                origin: request.origin,
                summary: request.summary,
                restoredFromVersion: request.restoredFromVersion)
            do {
                try await row.create(on: db)
                return next
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Abort(.internalServerError, reason: "Could not assign a version number")
    }
}
