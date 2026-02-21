// APIServer/Models/APITestSetup.swift

import Fluent
import Vapor
import Core

final class APITestSetup: Model, Content, @unchecked Sendable {
    static let schema = "test_setups"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "manifest")
    var manifest: String        // JSON blob of TestProperties

    @Field(key: "zip_path")
    var zipPath: String

    /// Path to the flat `.ipynb` file on disk (browser-mode setups only).
    /// Nil for worker-mode setups. Set when the setup is first uploaded
    /// (browser-mode) or after the instructor saves edits via
    /// `PUT /api/v1/testsetups/:id/assignment`.
    @OptionalField(key: "notebook_path")
    var notebookPath: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: String, manifest: String, zipPath: String, notebookPath: String? = nil) {
        self.id           = id
        self.manifest     = manifest
        self.zipPath      = zipPath
        self.notebookPath = notebookPath
    }
}
