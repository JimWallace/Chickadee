// APIServer/GitHub/GitHubAppRegistration.swift
//
// The registered GitHub App and its secrets file, read together (#1771).
//
// The row says an App is registered; the 0600 file holds what the row
// cannot (the private key, the client secret, the webhook secret). Five
// callers used to load the file with `try?` beside the row, so a lost or
// corrupt file read as "no App": the admin page said registered, students
// saw GitHub submission as unavailable, GitHub saw 404 on every delivery,
// and nothing said why. Every caller now asks here, a file problem is
// logged, and the admin page names it.

import Vapor

enum GitHubAppRegistration {
    /// Why a registered App's secrets cannot be used.
    enum SecretsProblem: Equatable, Sendable {
        /// The file is absent or empty.
        case missing(path: String)
        /// The file exists but does not decode.
        case unreadable(path: String, reason: String)

        var path: String {
            switch self {
            case .missing(let path), .unreadable(let path, _): path
            }
        }

        /// True for a file that is absent; false for one that will not decode.
        var isMissing: Bool {
            if case .missing = self { return true }
            return false
        }

        /// The one-line description for the log. The admin page writes its
        /// own copy from `isMissing` and `path`, so no decoder description
        /// reaches the page.
        var logDescription: String {
            switch self {
            case .missing(let path): "secrets file missing at \(path)"
            case .unreadable(let path, let reason): "secrets file unreadable at \(path): \(reason)"
            }
        }
    }

    enum State {
        /// No App is registered.
        case none
        /// The App and its secrets, both readable.
        case registered(app: APIGitHubApp, secrets: GitHubAppSecrets)
        /// The row exists but the file does not serve it.
        case secretsUnavailable(app: APIGitHubApp, problem: SecretsProblem)

        var app: APIGitHubApp? {
            switch self {
            case .none: nil
            case .registered(let app, _), .secretsUnavailable(let app, _): app
            }
        }

        var problem: SecretsProblem? {
            if case .secretsUnavailable(_, let problem) = self { return problem }
            return nil
        }
    }

    /// Reads the row and the file together.
    static func state(req: Request) async throws -> State {
        guard let app = try await APIGitHubApp.query(on: req.db).first() else { return .none }
        let path = req.application.githubAppSecretsFilePath
        do {
            guard let secrets = try GitHubAppSecrets.load(path: path) else {
                return .secretsUnavailable(app: app, problem: .missing(path: path))
            }
            return .registered(app: app, secrets: secrets)
        } catch {
            return .secretsUnavailable(app: app, problem: .unreadable(path: path, reason: "\(error)"))
        }
    }

    /// The App and its secrets, or nil when no App is registered or its
    /// secrets cannot be read. A secrets problem is logged at error level,
    /// so a lost file shows in the log rather than only as a 404.
    static func resolve(req: Request) async throws -> (app: APIGitHubApp, secrets: GitHubAppSecrets)? {
        switch try await state(req: req) {
        case .none:
            return nil
        case .registered(let app, let secrets):
            return (app, secrets)
        case .secretsUnavailable(_, let problem):
            req.logger.error(
                "GitHub App secrets unavailable",
                metadata: ["path": "\(problem.path)", "problem": "\(problem.logDescription)"])
            return nil
        }
    }
}
