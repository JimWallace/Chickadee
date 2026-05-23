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
