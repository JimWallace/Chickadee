// APIServer/Routes/Web/AdminRoutes+GitHub.swift
//
// Admin "GitHub" tab (docs/github-submissions.md slice 1): creating the GitHub
// App with the manifest flow, and removing the registration. The App's
// identifiers live in `github_apps`; its secrets arrive from GitHub directly
// and go to `.github-app-secrets`, so nobody copies a key by hand and nothing
// needs an environment variable.
//
//   GET  /admin/github           → admin-github.leaf (the manifest form, or the App)
//   GET  /admin/github/callback  → GitHub returns here with the code to exchange
//   POST /admin/github/delete    → remove the registration and the secrets file
//
// No row means GitHub submission is off, so registering an App is the switch
// that the privacy review (slice 0) gates.

import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    /// The session key for the `state` the manifest form sent to GitHub.
    static let githubManifestStateKey = "githubManifestState"

    /// Post-redirect notices, as keys so a query string cannot put arbitrary
    /// text on the page.
    enum GitHubAdminNotice: String {
        case registered, removed

        var message: String {
            switch self {
            case .registered: "GitHub App registered."
            case .removed: "GitHub App registration removed."
            }
        }
    }

    // MARK: - GET /admin/github

    @Sendable
    func githubPage(req: Request) async throws -> View {
        let notice = req.query[String.self, at: "ok"].flatMap(GitHubAdminNotice.init(rawValue:))
        let error = req.query[String.self, at: "error"].flatMap(GitHubAppRegistrationError.init(rawValue:))
        return try await renderGitHubPage(
            req: req, options: GitHubAppOptions(query: req), flashSuccess: notice?.message,
            flashError: error?.message)
    }

    // MARK: - GET /admin/github/callback

    @Sendable
    func githubCallback(req: Request) async throws -> Response {
        let expectedState = req.session.data[Self.githubManifestStateKey]
        req.session.data[Self.githubManifestStateKey] = nil
        do {
            let conversion = try await convertGitHubManifest(req: req, expectedState: expectedState)
            let app = try await saveGitHubApp(conversion, req: req)
            await AuditLogger.record(
                action: .githubAppRegistered, targetType: .githubApp, targetID: String(app.appID),
                metadata: ["slug": app.slug, "owner": app.ownerLogin ?? ""], on: req)
            return req.redirect(to: "/admin/github?ok=\(GitHubAdminNotice.registered.rawValue)")
        } catch let error as GitHubAppRegistrationError {
            return req.redirect(to: "/admin/github?error=\(error.rawValue)")
        }
    }

    // MARK: - POST /admin/github/delete

    @Sendable
    func deleteGitHubApp(req: Request) async throws -> Response {
        guard let app = try await APIGitHubApp.query(on: req.db).first() else {
            throw Abort(.notFound)
        }
        let appID = String(app.appID)
        let slug = app.slug
        try await app.delete(on: req.db)
        try GitHubAppSecrets.remove(path: req.application.githubAppSecretsFilePath)
        await AuditLogger.record(
            action: .githubAppRemoved, targetType: .githubApp, targetID: appID,
            metadata: ["slug": slug], on: req)
        return req.redirect(to: "/admin/github?ok=\(GitHubAdminNotice.removed.rawValue)")
    }

    // MARK: - Helpers

    /// Checks the callback and exchanges its code. Every refusal is a
    /// `GitHubAppRegistrationError`, which the page shows as one sentence.
    private func convertGitHubManifest(
        req: Request, expectedState: String?
    ) async throws -> GitHubManifestConversion {
        if try await APIGitHubApp.query(on: req.db).first() != nil {
            throw GitHubAppRegistrationError.alreadyRegistered
        }
        guard let expectedState, req.query[String.self, at: "state"] == expectedState else {
            throw GitHubAppRegistrationError.stateMismatch
        }
        guard let code = req.query[String.self, at: "code"], GitHubManifestCode.isWellFormed(code) else {
            throw GitHubAppRegistrationError.missingCode
        }
        do {
            return try await req.application.githubManifestConverter(code)
        } catch {
            req.logger.warning("GitHub manifest conversion failed", metadata: ["error": "\(error)"])
            throw GitHubAppRegistrationError.conversionFailed
        }
    }

    /// Writes the secrets file, then the row. If the row cannot be saved, the
    /// file is removed again, so the two never disagree about whether an App
    /// is registered.
    private func saveGitHubApp(
        _ conversion: GitHubManifestConversion, req: Request
    ) async throws -> APIGitHubApp {
        let path = req.application.githubAppSecretsFilePath
        do {
            try conversion.secrets.write(path: path)
        } catch {
            req.logger.error("GitHub App secrets not written", metadata: ["error": "\(error)"])
            throw GitHubAppRegistrationError.secretsNotWritten
        }
        let app = APIGitHubApp(conversion: conversion)
        do {
            try await app.save(on: req.db)
        } catch {
            try? GitHubAppSecrets.remove(path: path)
            throw error
        }
        return app
    }

    private func renderGitHubPage(
        req: Request, options: GitHubAppOptions, flashSuccess: String?, flashError: String?
    ) async throws -> View {
        let organizationText = options.organizationText
        let registration = try await GitHubAppRegistration.state(req: req)
        let registered = registration.app
        let baseURL = req.application.securityConfiguration.publicBaseURL
        var creation: GitHubAppCreationContext?
        var flashError = flashError
        if registered == nil, baseURL != nil {
            let trimmed = organizationText.trimmingCharacters(in: .whitespacesAndNewlines)
            let organization = GitHubOrganizationName(trimmed)
            if !trimmed.isEmpty, organization == nil {
                flashError = GitHubAppRegistrationError.invalidOrganization.message
            } else if let manifest = GitHubAppManifest(
                publicBaseURL: baseURL, organization: organization,
                courseRepositories: options.courseRepositories, pushEvents: options.pushEvents,
                commitStatuses: options.commitStatuses)
            {
                let state = LTILaunchSecrets.randomToken()
                req.session.data[Self.githubManifestStateKey] = state
                // The manifest form posts to github.com, so this page's CSP must
                // allow it. The browser checks form-action against the page
                // that holds the form (the BrightSpace page does the same).
                SecurityHeadersMiddleware.allowFormAction("https://github.com", on: req)
                creation = GitHubAppCreationContext(
                    actionURL: manifest.creationURL(state: state),
                    manifestJSON: try manifest.json(),
                    ownerLabel: organization.map { "the organization \($0.value)" } ?? "your GitHub account")
            }
        }
        let ctx = AdminGitHubContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "github",
            baseURLConfigured: baseURL != nil,
            app: registered.map(AdminGitHubAppDetails.init(app:)),
            secretsUnavailable: registration.problem != nil,
            secretsMissing: registration.problem?.isMissing ?? false,
            secretsPath: registration.problem?.path ?? "",
            creation: creation,
            organization: organizationText,
            organizationOpen: options.anySet,
            courseRepositories: options.courseRepositories,
            pushEvents: options.pushEvents,
            commitStatuses: options.commitStatuses,
            flashSuccess: flashSuccess,
            flashError: flashError)
        return try await req.view.render("admin-github", ctx)
    }
}

/// The registration options on the admin GitHub page, read from its GET form.
private struct GitHubAppOptions {
    let organizationText: String
    let courseRepositories: Bool
    let pushEvents: Bool
    let commitStatuses: Bool

    init(query req: Request) {
        organizationText = req.query[String.self, at: "org"] ?? ""
        courseRepositories = req.query[String.self, at: "courseRepositories"] != nil
        pushEvents = req.query[String.self, at: "pushEvents"] != nil
        commitStatuses = req.query[String.self, at: "commitStatuses"] != nil
    }

    /// True when any option is set, so the disclosure stays open.
    var anySet: Bool {
        courseRepositories || pushEvents || commitStatuses
            || !organizationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
