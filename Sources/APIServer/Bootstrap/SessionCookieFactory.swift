// APIServer/Bootstrap/SessionCookieFactory.swift
//
// Builds the session cookie issued by the Fluent session store.
//
// The cookie is *session-scoped* — no `expires`/`maxAge` — so the browser
// also drops it when the browsing session ends.  A session ends when:
//   (1) the user logs out (AuthRoutes.logout), or
//   (2) the idle timeout fires (SessionIdleTimeoutMiddleware + idle-logout.js), or
//   (3) the browser is closed.
// In cases (1) and (2) the handler calls `req.session.destroy()`, which deletes
// the persisted Fluent session row immediately and emits a Set-Cookie that
// expires the client cookie — so logout no longer depends on the browser being
// closed.  SessionReaperService is now only a backstop for rows orphaned by
// abandoned (never-logged-out) sessions.
//
// Note: browsers with "continue where you left off" / session-restore resurrect
// session cookies on relaunch, but since logout deletes the server-side row a
// resurrected cookie no longer maps to a valid session.

import Vapor

func chickadeeSessionCookie(sessionID: SessionID, isSecure: Bool) -> HTTPCookies.Value {
    HTTPCookies.Value(
        string: sessionID.string,
        expires: nil,
        maxAge: nil,
        domain: nil,
        path: "/",
        isSecure: isSecure,
        isHTTPOnly: true,
        sameSite: .lax
    )
}

/// Name of the short-lived marker set on logout. When `/auth/sso/start` sees
/// it, it appends `prompt=login` to the authorization request (forcing the IdP
/// to re-authenticate) and clears the marker. This stops an explicit logout
/// from being silently undone by Duo's still-live SSO session, while leaving
/// normal day-to-day sign-ins as one-click SSO.
let reauthMarkerCookieName = "chickadee_reauth"

/// Session-scoped marker cookie (no `maxAge`, so it dies with the browsing
/// session). It is consumed on the next `/auth/sso/start`, so it only ever
/// forces re-authentication for the first sign-in after a logout.
func chickadeeReauthMarkerCookie(isSecure: Bool) -> HTTPCookies.Value {
    HTTPCookies.Value(
        string: "1",
        expires: nil,
        maxAge: nil,
        domain: nil,
        path: "/",
        isSecure: isSecure,
        isHTTPOnly: true,
        sameSite: .lax
    )
}

extension Session {
    /// Session-fixation defense — call right before authenticating a user.
    ///
    /// Dropping the id makes `SessionsMiddleware` issue a brand-new session id
    /// and `Set-Cookie` when it commits this (still-valid) session on the way
    /// out, so the authenticated session gets an identifier the pre-login
    /// cookie never had. The pre-login row keeps its old id but never receives
    /// the auth marker (that lands on the new id), so a session id fixed onto
    /// the victim before login can't be used to ride the resulting session.
    func rotateID() {
        self.id = nil
    }
}
