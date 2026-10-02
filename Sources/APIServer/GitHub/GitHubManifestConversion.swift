// APIServer/GitHub/GitHubManifestConversion.swift
//
// The one GitHub call slice 1 makes: exchanging the manifest code for the new
// App's credentials (`POST /app-manifests/{code}/conversions`). The code is the
// only credential, it works once, and it expires after one hour, so the call
// needs no authentication.
//
// The call is a closure on the Application, so tests swap in a fake and never
// reach the network (the `LTIPlatformKeyCache` seam).

import Foundation
import Vapor

/// What GitHub returns for a converted manifest. Only the fields Chickadee
/// keeps are decoded.
struct GitHubManifestConversion: Decodable, Sendable, Equatable {
    struct Owner: Decodable, Sendable, Equatable {
        let login: String
    }

    let id: Int
    let slug: String
    let name: String
    let clientID: String
    let clientSecret: String
    let webhookSecret: String?
    let pem: String
    let htmlURL: String
    let owner: Owner?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, pem, owner
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case webhookSecret = "webhook_secret"
        case htmlURL = "html_url"
    }

    /// The part the secrets file keeps.
    var secrets: GitHubAppSecrets {
        GitHubAppSecrets(privateKeyPEM: pem, clientSecret: clientSecret, webhookSecret: webhookSecret)
    }
}

enum GitHubManifestCode {
    /// True for text that can be a manifest code. It goes into a URL path, so
    /// anything else is refused before a request is made.
    static func isWellFormed(_ code: String) -> Bool {
        (1...200).contains(code.count)
            && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// Exchanges a well-formed manifest code for the App's credentials.
typealias GitHubManifestConverter = @Sendable (String) async throws -> GitHubManifestConversion

private struct GitHubManifestConverterKey: StorageKey {
    typealias Value = GitHubManifestConverter
}

private struct GitHubAppSecretsFilePathKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// The live converter calls api.github.com; tests replace it.
    var githubManifestConverter: GitHubManifestConverter {
        get {
            if let converter = storage[GitHubManifestConverterKey.self] { return converter }
            let github = GitHubTransport(app: self)
            return { code in
                let response = try await github.send(
                    .POST, GitHubTransport.api + "/app-manifests/\(GitHubRepoClient.pathSegment(code))/conversions",
                    headers: GitHubTransport.apiHeaders())
                guard response.status == .created || response.status == .ok else {
                    throw GitHubAppRegistrationError.conversionFailed
                }
                return try response.content.decode(GitHubManifestConversion.self)
            }
        }
        set { storage[GitHubManifestConverterKey.self] = newValue }
    }

    /// Where the App's secrets live. Derived from the working directory, like
    /// `.lti-tool-key`, so it needs no environment variable.
    var githubAppSecretsFilePath: String {
        get {
            storage[GitHubAppSecretsFilePathKey.self]
                ?? (DirectoryConfiguration.detect().workingDirectory + ".github-app-secrets")
        }
        set { storage[GitHubAppSecretsFilePathKey.self] = newValue }
    }
}
