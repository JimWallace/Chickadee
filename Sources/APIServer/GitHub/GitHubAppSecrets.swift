// APIServer/GitHub/GitHubAppSecrets.swift
//
// The GitHub App's three secrets (docs/github-submissions.md "Where the values
// live"): the private key that signs installation-token requests, the OAuth
// client secret for account linking, and the webhook secret. They live in
// `.github-app-secrets` in the working directory, mode 0600, beside
// `.lti-tool-key` and `.worker-secret`. The database holds only the values
// that are not secret.

import Foundation

struct GitHubAppSecrets: Codable, Sendable, Equatable {
    let privateKeyPEM: String
    let clientSecret: String
    /// Nil when GitHub returned none: the App has no webhook until slice 5.
    let webhookSecret: String?

    /// Reads the secrets at `path`, or nil when the file is absent or empty.
    static func load(path: String) throws -> GitHubAppSecrets? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        return try JSONDecoder().decode(GitHubAppSecrets.self, from: data)
    }

    /// Writes the secrets to `path` with mode 0600. The file is created with
    /// that mode, so the secrets are never readable by others, not even
    /// between the write and a later permission change.
    func write(path: String) throws {
        let data = try JSONEncoder().encode(self)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        guard fileManager.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw GitHubAppRegistrationError.secretsNotWritten }
    }

    /// Deletes the file at `path`. An absent file is not an error.
    static func remove(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
