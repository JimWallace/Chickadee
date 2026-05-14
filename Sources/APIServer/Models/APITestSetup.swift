// APIServer/Models/APITestSetup.swift

import Core
import Fluent
import Vapor

final class APITestSetup: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "test_setups"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "manifest")
    var manifest: String  // JSON blob of TestProperties

    @Field(key: "zip_path")
    var zipPath: String

    /// Path to the flat `.ipynb` file on disk (browser-mode setups only).
    /// Nil for worker-mode setups. Set when the setup is first uploaded
    /// (browser-mode) or after the instructor saves edits via
    /// `PUT /api/v1/testsetups/:id/assignment`.
    @OptionalField(key: "notebook_path")
    var notebookPath: String?

    /// The course this test setup belongs to.
    @Field(key: "course_id")
    var courseID: UUID

    /// SHA-256 hex of the `manifest` bytes at the time of the most recent
    /// "retest every submission" fan-out for this setup.  The auto-retest
    /// trigger on assignment save compares the current manifest hash against
    /// this value — if unchanged, the save was a cosmetic/metadata edit and
    /// the mass retest is skipped.  Nil until the first retest has been
    /// fanned out.  See v0.4.93.
    @OptionalField(key: "last_retested_manifest_hash")
    var lastRetestedManifestHash: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: String, manifest: String, zipPath: String, notebookPath: String? = nil,
        courseID: UUID
    ) {
        self.id = id
        self.manifest = manifest
        self.zipPath = zipPath
        self.notebookPath = notebookPath
        self.courseID = courseID
    }
}
