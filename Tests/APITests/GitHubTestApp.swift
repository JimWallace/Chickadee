// Tests/APITests/GitHubTestApp.swift
//
// The registered GitHub App that the GitHub suites share: one RSA key for the
// whole test process, and the App row plus its secrets file.
//
// Each suite used to make its own 2048-bit key with `(try? ...) ?? ""`. A key
// that failed to generate became an empty PEM, and the test failed later, at
// the first signature, with a message that named the wrong cause. Here a
// failure throws its own error at the first test that asks for the key.

import CryptoExtras
import Fluent
import Foundation
import Vapor

@testable import APIServer

enum GitHubTestApp {

    private static let generatedKey = Result {
        try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
    }

    /// The private key of the test App, as PEM. Throws the generation error.
    static func privateKeyPEM() throws -> String {
        try generatedKey.get()
    }

    /// Makes a fresh directory for the App secrets file and points `app` at
    /// it. The caller removes the directory.
    static func useSecretsDirectory(on app: Application, prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        return directory
    }

    /// Saves the App row (ID 42, `chickadee-courses`). `pem` nil uses the
    /// shared key. `writesSecrets` also writes the secrets file, which every
    /// route that signs or verifies reads.
    static func register(
        on app: Application,
        pem: String? = nil,
        clientSecret: String = "client-secret",
        webhookSecret: String? = nil,
        writesSecrets: Bool = true
    ) async throws {
        let pem = try pem ?? privateKeyPEM()
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: clientSecret, webhookSecret: webhookSecret, pem: pem,
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        if writesSecrets {
            try GitHubAppSecrets(privateKeyPEM: pem, clientSecret: clientSecret, webhookSecret: webhookSecret)
                .write(path: app.githubAppSecretsFilePath)
        }
    }
}
