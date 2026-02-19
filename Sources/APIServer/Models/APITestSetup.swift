// APIServer/Models/APITestSetup.swift

import Fluent
import Vapor
import Core

final class APITestSetup: Model, Content, @unchecked Sendable {
    static let schema = "test_setups"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "language")
    var language: String

    @Field(key: "manifest")
    var manifest: String        // JSON blob of TestSetupManifest

    @Field(key: "zip_path")
    var zipPath: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: String, language: String, manifest: String, zipPath: String) {
        self.id       = id
        self.language = language
        self.manifest = manifest
        self.zipPath  = zipPath
    }
}
