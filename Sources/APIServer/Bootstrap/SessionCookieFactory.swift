// APIServer/Bootstrap/SessionCookieFactory.swift
//
// Builds the session cookie issued by the Fluent session store.
//
// The cookie is *session-scoped* — no `expires`/`maxAge` — so the browser
// drops it when the browsing session ends.  Closing the browser therefore
// logs the user out (institutional requirement).  The two ways a session ends
// are now (1) browser close and (2) the idle timeout
// (SessionIdleTimeoutMiddleware + idle-logout.js); the orphaned Fluent session
// row is reaped later by SessionReaperService.
//
// Caveat: browsers with "continue where you left off" / session-restore
// resurrect session cookies on relaunch — client behaviour we can't override,
// which is why the idle timeout is the real backstop.

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
