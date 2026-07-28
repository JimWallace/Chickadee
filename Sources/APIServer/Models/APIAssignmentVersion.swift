// APIServer/Models/APIAssignmentVersion.swift
//
// One immutable snapshot of an assignment's *content* — the manifest, the
// setup zip's contents, and the starter notebook — taken after a content edit.
// Together the rows for one `test_setup_id` form a linear, append-only history
// that is never rewritten and never deleted; see docs/assignment-versioning.md.
//
// Byte storage is external: `file_map` and `notebook_hash` name content-addressed
// blobs in `AssignmentVersionBlobStore`, so an unchanged dataset or notebook is
// stored once no matter how many versions reference it. Only the manifest is
// inline, because it is small, always differs, and is what most reads want.
//
// `test_setup_id` deliberately carries NO foreign key. `deleteAssignment`
// hard-deletes the `test_setups` row along with the zip and notebook, so an FK
// would cascade the history away at exactly the moment recovery matters. The
// FK is on `course_id` alone (history dies with its course, per the retention
// rules) and `assignment_id` is nullable so a version can outlive its assignment.

import Fluent
import Vapor

final class APIAssignmentVersion: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "assignment_versions"

    @ID(key: .id)
    var id: UUID?

    /// The test setup whose content this snapshots. Plain string, no FK — see
    /// the file comment.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The assignment that published the setup at snapshot time. Nullable: a
    /// version outlives a deleted assignment, and hidden drafts have none.
    @OptionalField(key: "assignment_id")
    var assignmentID: UUID?

    /// Scoping and retention key. The only FK on this table.
    @Field(key: "course_id")
    var courseID: UUID

    /// 1-based, monotone per `test_setup_id`. Unique with `test_setup_id`, so
    /// two concurrent edits can't both claim the same number.
    @Field(key: "version_number")
    var versionNumber: Int

    /// The full `TestProperties` JSON as it stood at snapshot time, inline.
    @Field(key: "manifest")
    var manifest: String

    /// SHA-256 of `manifest`, via the shared `manifestHash(_:)` helper.
    @Field(key: "manifest_hash")
    var manifestHash: String

    /// JSON object mapping a zip entry path to its blob hash. Read through
    /// `decodedFileMap()`.
    @Field(key: "file_map")
    var fileMapJSON: String

    /// Blob hash of the starter notebook; nil when the setup has none.
    @OptionalField(key: "notebook_hash")
    var notebookHash: String?

    /// Digest over the whole snapshot (manifest + file map + notebook). The
    /// dedupe key: a record whose hash matches the newest version is skipped.
    @Field(key: "snapshot_hash")
    var snapshotHash: String

    /// Who caused the edit. Nil for system-originated snapshots (baseline,
    /// import). Set null rather than cascade if the user is deleted — the
    /// history survives, and `actorUsername` preserves the attribution.
    @OptionalField(key: "actor_user_id")
    var actorUserID: UUID?

    /// Denormalized at write time so a deleted user doesn't orphan the
    /// attribution — same reasoning as `audit_log.actor_username`.
    @OptionalField(key: "actor_username")
    var actorUsername: String?

    /// What produced this version, e.g. `mcp:update_suite`, `web:save_edit`,
    /// `clone`, `baseline`, `restore:7`. See `AssignmentVersionOrigin`.
    @Field(key: "origin")
    var origin: String

    /// One short human-readable line describing the change, when the caller
    /// can cheaply produce one.
    @OptionalField(key: "summary")
    var summary: String?

    /// Set when this version was produced by restoring an earlier one. History
    /// stays linear: a restore appends, it never rewinds the counter.
    @OptionalField(key: "restored_from_version")
    var restoredFromVersion: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        testSetupID: String,
        assignmentID: UUID?,
        courseID: UUID,
        versionNumber: Int,
        snapshot: AssignmentVersionSnapshot,
        actorUserID: UUID? = nil,
        actorUsername: String? = nil,
        origin: String,
        summary: String? = nil,
        restoredFromVersion: Int? = nil
    ) {
        self.id = id
        self.testSetupID = testSetupID
        self.assignmentID = assignmentID
        self.courseID = courseID
        self.versionNumber = versionNumber
        self.manifest = snapshot.manifest
        self.manifestHash = snapshot.manifestHash
        self.fileMapJSON = snapshot.encodedFileMap()
        self.notebookHash = snapshot.notebookHash
        self.snapshotHash = snapshot.snapshotHash
        self.actorUserID = actorUserID
        self.actorUsername = actorUsername
        self.origin = origin
        self.summary = summary
        self.restoredFromVersion = restoredFromVersion
    }
}

extension APIAssignmentVersion {
    /// Decodes `fileMapJSON` back into a path → blob-hash map. Returns an empty
    /// map if the column is malformed — a corrupt map must not crash a history
    /// listing, and every consumer treats "no files" as a recoverable state it
    /// can report rather than a fatal one.
    func decodedFileMap() -> [String: String] {
        guard let data = fileMapJSON.data(using: .utf8),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }
}
