// APIServer/MCP/OAuth/MCPOAuthRoutes+SwitchAccount.swift
//
// POST /oauth/authorize/switch-account: the consent screen's "Use a different
// account" button.
//
// The consent screen uses whoever is signed in to this browser.  One person
// can hold two accounts, an instructor for the content surface and an admin for
// the diagnostics surface, and before this route the only way to authorize the
// other one was a private window.  This signs the browser out and sends it to
// /login with the same authorize request queued, so `postLoginRedirect`
// returns the new account to this consent screen.

import Fluent
import Foundation
import Vapor

extension MCPOAuthRoutes {
    /// Where the consent screen's switch-account form posts.
    static let switchAccountPath = "/oauth/authorize/switch-account"

    /// The form body: the authorize request to come back to.
    struct SwitchAccountBody: Content {
        let returnTo: String

        enum CodingKeys: String, CodingKey {
            case returnTo = "return_to"
        }
    }

    /// True for a same-origin `/oauth/authorize` request path.  Anything else
    /// is refused, so the form cannot be turned into an open redirect or into
    /// a sign-out that lands on an arbitrary page.
    static func isAuthorizeReturnPath(_ path: String) -> Bool {
        path.hasPrefix("/oauth/authorize?")
    }

    @Sendable
    func switchAccount(req: Request) async throws -> Response {
        let body = try await req.decodeContent(SwitchAccountBody.self)
        guard Self.isAuthorizeReturnPath(body.returnTo) else {
            throw AppError.badRequest(reason: "return_to must be an /oauth/authorize request.")
        }

        if let user = req.auth.get(APIUser.self) {
            await AuditLogger.record(
                action: .logout,
                targetType: .auth,
                targetID: user.id?.uuidString,
                metadata: ["username": user.username, "reason": "switch_account"],
                actorOverride: user,
                on: req
            )
        }

        // Sign out, but keep a session to carry the queued authorize request
        // through /login.  Clearing the data drops the auth marker, the CSRF
        // secret and any stored SSO tokens; the new sign-in rotates the id.
        req.auth.logout(APIUser.self)
        req.session.data = SessionData()
        req.session.data[Self.returnToSessionKey] = body.returnTo

        // Force the IdP to ask for credentials again.  Without this, Duo's own
        // session signs the same account straight back in.
        let response = req.redirect(to: "/login")
        response.cookies[reauthMarkerCookieName] = chickadeeReauthMarkerCookie(
            isSecure: req.application.securityConfiguration.sessionCookieSecure)
        return response
    }
}
