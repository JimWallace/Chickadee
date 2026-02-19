// APIServer/Models/APITestSetup.swift

import Fluent
import Vapor
import Core

// @unchecked Sendable: Fluent's Model property wrappers are not Sendable.
// Access is always through async Fluent/Vapor contexts which ensure safety.
final class APITestSetup: Model, Content, @unchecked Sendable {
    static let schema = "test_setups"

    @ID(custom: "id", generatedBy: .user)
    var id: String?

    @Field(key: "manifest")
    var manifest: String        // JSON blob of TestProperties

    @Field(key: "zip_path")
    var zipPath: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: String, manifest: String, zipPath: String) {
        self.id       = id
        self.manifest = manifest
        self.zipPath  = zipPath
    }
}
