// APIServer/LTI/LTIIdentityResolver.swift
//
// Finds or creates the Chickadee account for a validated LTI launch
// (docs/lti-1-3.md "Identity"). In order:
//
// 1. A known (platform, subject) link resolves to its account.
// 2. When the platform is trusted for usernames and the launch carries a
//    `username` custom parameter, the launch links to the account with that
//    username, or creates it. Created accounts are shaped like a pre-SSO
//    stub, so a later DUO sign-in adopts the same account instead of making
//    a second one.
// 3. Otherwise the subject gets its own account, named from a hash of the
//    platform and subject, so it cannot collide with a real username.
//
// A launch never links to an admin or MCP account, never signs in to one
// through a link made earlier, and never gives one account two subjects on
// one platform: each would let an LMS user take over an account the LMS
// does not own.

import Crypto
import Fluent
import Foundation

enum LTIIdentityResolver {
    enum Failure: Error, Equatable {
        /// The trusted username, or an existing link, names an account a
        /// launch may not claim.
        case linkRefused(username: String)
    }

    struct Resolution {
        let user: APIUser
        /// True when this launch created the account.
        let created: Bool
    }

    static func resolve(
        launch: LTIValidatedLaunch,
        platform: APILTIPlatform,
        authMode: AuthMode,
        on db: Database
    ) async throws -> Resolution {
        let platformID = try platform.requireID()
        // Two first launches of one subject can race: on the (platform,
        // subject) unique index, or on the username when both create the
        // account. The loser's insert fails, and a second pass finds what the
        // winner wrote. A refusal is a decision, not a race, and is not retried.
        do {
            return try await resolveOnce(
                launch: launch, platform: platform, platformID: platformID, authMode: authMode, on: db)
        } catch let failure as Failure {
            throw failure
        } catch {
            return try await resolveOnce(
                launch: launch, platform: platform, platformID: platformID, authMode: authMode, on: db)
        }
    }

    private static func resolveOnce(
        launch: LTIValidatedLaunch,
        platform: APILTIPlatform,
        platformID: UUID,
        authMode: AuthMode,
        on db: Database
    ) async throws -> Resolution {
        if let user = try await linkedUser(platformID: platformID, subject: launch.subject, on: db) {
            return Resolution(user: user, created: false)
        }

        let resolution: Resolution
        if platform.trustUsername == true, let username = trustedUsername(launch) {
            resolution = try await linkOrCreate(
                username: username, launch: launch, platformID: platformID,
                authProvider: authMode == .local ? "lti" : "duo-oidc", on: db)
        } else {
            let username = opaqueUsername(platformID: platformID, subject: launch.subject)
            let existing = try await APIUser.query(on: db)
                .filter(\.$username == username)
                .filter(\.$authProvider == "lti")
                .first()
            resolution =
                if let existing {
                    Resolution(user: existing, created: false)
                } else {
                    Resolution(
                        user: try await create(username: username, launch: launch, authProvider: "lti", on: db),
                        created: true)
                }
        }

        do {
            try await APILTIIdentity(
                platformID: platformID, subject: launch.subject, userID: try resolution.user.requireID()
            ).save(on: db)
        } catch {
            // The other first launch won the (platform, subject) index: its
            // link is the one that counts.
            if let user = try await linkedUser(platformID: platformID, subject: launch.subject, on: db) {
                return Resolution(user: user, created: false)
            }
            throw error
        }
        return resolution
    }

    /// The account a known (platform, subject) link resolves to, or nil.
    /// An admin or MCP account is refused here too, not only when the link
    /// is made: an account can become one later, by a role change or when an
    /// SSO admin adopts a stub that a trusted launch created
    /// (docs/compliance/lti-audit-2026-10.md L-2).
    private static func linkedUser(platformID: UUID, subject: String, on db: Database) async throws -> APIUser? {
        guard
            let identity = try await APILTIIdentity.query(on: db)
                .filter(\.$platformID == platformID)
                .filter(\.$subject == subject)
                .first(),
            let user = try await APIUser.find(identity.userID, on: db)
        else { return nil }
        guard !user.isAdmin, !user.isMCPAgent else { throw Failure.linkRefused(username: user.username) }
        return user
    }

    /// The platform's `username` custom parameter, trimmed and lowercased, or
    /// nil when the launch does not carry a usable one.
    static func trustedUsername(_ launch: LTIValidatedLaunch) -> String? {
        guard case .string(let raw) = launch.custom["username"] else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A platform that does not substitute the variable sends it verbatim.
        guard !key.isEmpty, !key.hasPrefix("$") else { return nil }
        return key
    }

    /// `lti-` plus 16 hex digits of SHA-256(platform|subject). Stable, so the
    /// same subject always names the same account, and opaque, so it reveals
    /// nothing about the person.
    static func opaqueUsername(platformID: UUID, subject: String) -> String {
        let digest = SHA256.hash(data: Data("\(platformID.uuidString)|\(subject)".utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "lti-" + hex
    }

    private static func linkOrCreate(
        username: String, launch: LTIValidatedLaunch, platformID: UUID, authProvider: String,
        on db: Database
    ) async throws -> Resolution {
        guard let existing = try await APIUser.query(on: db).filter(\.$username == username).first() else {
            return Resolution(
                user: try await create(username: username, launch: launch, authProvider: authProvider, on: db),
                created: true)
        }
        let alreadyLinked =
            try await APILTIIdentity.query(on: db)
            .filter(\.$platformID == platformID)
            .filter(\.$userID == existing.requireID())
            .first() != nil
        guard !existing.isAdmin, !existing.isMCPAgent, !alreadyLinked else {
            throw Failure.linkRefused(username: username)
        }
        return Resolution(user: existing, created: false)
    }

    private static func create(
        username: String, launch: LTIValidatedLaunch, authProvider: String, on db: Database
    ) async throws -> APIUser {
        let user = APIUser(
            username: username,
            passwordHash: "",
            role: UserRole.user.rawValue,
            authProvider: authProvider,
            email: launch.email,
            displayName: launch.name)
        try await user.save(on: db)
        return user
    }
}
