import Fluent
import Vapor

/// Wraps a session driver so a session that nothing touched is not rewritten.
///
/// Vapor's `SessionsMiddleware` calls `updateSession` on the way out of every
/// request that arrived with a session cookie, whether or not anything in the
/// session changed — it has no dirty flag to consult. With the Fluent driver
/// that is an `UPDATE` on `_fluent_sessions`: a row write plus WAL, on the one
/// table every authenticated request already reads.
///
/// Almost nothing writes session data. It changes at login, during the OIDC
/// handshake, when the active course switches, and when a draft form stashes
/// state — a handful of requests per session. Every other request was paying a
/// write to store back the bytes it had just read, including static assets that
/// miss the editor fast path and the two-second poll a student's result page
/// runs while a submission is pending.
///
/// Skipping is behaviour-preserving because `updateSession` sets the data
/// column and nothing else: no expiry, no touched-at. Session lifetime comes
/// from `created_at`, stamped once at create and reaped by
/// `SessionReaperService`; the idle timeout is enforced against the user row by
/// `SessionIdleTimeoutMiddleware`, not against this one. So a session that is
/// read and not modified is, on disk, already exactly what the write would
/// have produced.
struct UnchangedSessionSkippingDriver: SessionDriver {
    /// The payload `readSession` handed back for this request, so the write
    /// side can tell an untouched session from a modified one. Request storage
    /// is the right scope: it lives exactly as long as the comparison is valid.
    private struct LoadedSessionDataKey: StorageKey {
        typealias Value = SessionData
    }

    let base: any SessionDriver

    func createSession(_ data: SessionData, for request: Request) -> EventLoopFuture<SessionID> {
        base.createSession(data, for: request)
    }

    func readSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<SessionData?> {
        base.readSession(sessionID, for: request).map { data in
            if let data {
                request.storage[LoadedSessionDataKey.self] = data
            }
            return data
        }
    }

    func updateSession(
        _ sessionID: SessionID,
        to data: SessionData,
        for request: Request
    ) -> EventLoopFuture<SessionID> {
        if let loaded = request.storage[LoadedSessionDataKey.self], loaded == data {
            return request.eventLoop.makeSucceededFuture(sessionID)
        }
        return base.updateSession(sessionID, to: data, for: request)
    }

    func deleteSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<Void> {
        base.deleteSession(sessionID, for: request)
    }
}
