// Tests/APITests/GitHub/GitHubAppSecretsTests.swift
//
// The GitHub App secrets file (docs/github-submissions.md "Where the values
// live"): a round trip, mode 0600 from the moment it exists, and removal.

import Foundation
import Testing

@testable import APIServer

@Suite final class GitHubAppSecretsTests {
    let directory: URL
    var path: String { directory.appendingPathComponent(".github-app-secrets").path }

    static let secrets = GitHubAppSecrets(
        privateKeyPEM: "-----BEGIN RSA PRIVATE KEY-----\nkey\n-----END RSA PRIVATE KEY-----\n",
        clientSecret: "client-secret", webhookSecret: nil)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test func absentFileLoadsAsNil() throws {
        #expect(try GitHubAppSecrets.load(path: path) == nil)
    }

    @Test func writeThenLoadRoundTrips() throws {
        try Self.secrets.write(path: path)
        #expect(try GitHubAppSecrets.load(path: path) == Self.secrets)
    }

    @Test func fileIsOwnerReadWriteOnly() throws {
        try Self.secrets.write(path: path)
        #expect(try permissions() == 0o600)
    }

    @Test func overwritingAWiderFileLeavesItAt0600() throws {
        _ = FileManager.default.createFile(
            atPath: path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
        try Self.secrets.write(path: path)
        #expect(try permissions() == 0o600)
        #expect(try GitHubAppSecrets.load(path: path) == Self.secrets)
    }

    @Test func removeDeletesTheFileAndToleratesAnAbsentOne() throws {
        try Self.secrets.write(path: path)
        try GitHubAppSecrets.remove(path: path)
        #expect(!FileManager.default.fileExists(atPath: path))
        try GitHubAppSecrets.remove(path: path)
    }
}
