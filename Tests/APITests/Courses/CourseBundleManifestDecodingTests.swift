// Tests/APITests/Courses/CourseBundleManifestDecodingTests.swift
//
// Decoding tests for the course bundle manifest.

import Core
import Foundation
import Testing

/// Decoding a bundle manifest needs no app.
@Suite struct CourseBundleManifestDecodingTests {
    /// A bundle exported before content items existed omits the key entirely;
    /// it must decode (contentItems == nil) and import without error.
    @Test func manifestWithoutContentItemsDecodesToNil() throws {
        let json = """
            {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z","exportedBy":"admin",
             "chickadeeVersion":"0.0.0","course":{"code":"OLD","name":"Old"},
             "users":[],"enrolledUserBundleIDs":[],"assignments":[],"testSetups":[],
             "submissions":[],"results":[]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CourseBundleManifest.self, from: Data(json.utf8))
        #expect(manifest.contentItems == nil)
        #expect(manifest.sections == nil)
    }
}
