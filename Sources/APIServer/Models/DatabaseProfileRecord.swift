// APIServer/Models/DatabaseProfileRecord.swift
//
// The last database configuration the server saw, for the admin Overview's
// Database card (`DatabaseProfileService`). One row, keyed `current`.

import Fluent
import Foundation

/// The tracked database configuration, the one before it, and when it took
/// effect. Written only through `DatabaseProfileService.record`, whose
/// insert and compare-and-set update keep one row and one audit entry per
/// change when two servers boot together.
final class DatabaseProfileRecord: Model, @unchecked Sendable {
    // @unchecked Sendable: Fluent's property wrappers are what the compiler
    // cannot check; the row is written only through conditional statements.
    static let schema = "database_profile"

    /// The one key the table holds.
    static let currentKey = "current"

    @ID(custom: "key", generatedBy: .user)
    var id: String?

    @Field(key: "fingerprint_json")
    var fingerprint: DatabaseFingerprint

    /// The configuration before the current one, nil until the first change.
    @OptionalField(key: "previous_json")
    var previous: DatabaseFingerprint?

    /// When the current configuration was first seen.
    @Field(key: "since")
    var since: Date

    init() {}

    init(fingerprint: DatabaseFingerprint, since: Date) {
        self.id = Self.currentKey
        self.fingerprint = fingerprint
        self.previous = nil
        self.since = since
    }
}
