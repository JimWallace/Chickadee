// APIServer/Routes/Web/WebRoutes+EditorReset.swift
//
// Student self-service "reset the notebook editor" page.
//
// When the in-browser JupyterLite editor wedges — a Python kernel that spins
// forever and never finishes loading — the cause is usually persisted browser
// state for our origin: a stale service worker, a corrupted IndexedDB-backed
// JupyterLite Drive, or a cached asset.  notebook.js already unregisters stale
// service workers and the `?v=#appVersion()` cache-buster refreshes JS/CSS on
// each release, but neither touches IndexedDB — the most likely culprit for a
// kernel that won't boot even after a plain reload.
//
// This route is the server-side equivalent of "Clear site data", scoped to
// Chickadee and handed to a stuck student (or a TA) as a one-click fix: the
// POST response carries `Clear-Site-Data: "cache", "storage"`, which clears the
// origin's cache storage, IndexedDB, and service-worker registrations in one
// shot.  It deliberately does NOT clear "cookies", so the student stays logged
// in — they land back in the editor with a clean slate, not a login page.
//
// It is a two-step, CSRF-protected flow so a cross-origin page can't silently
// wipe a student's in-progress notebook: GET renders a confirmation page, and
// the POST (carrying the session's CSRF token, enforced by the auth group's
// CSRF middleware) performs the clear.

import Core
import Foundation
import Vapor

extension WebRoutes {

    /// Leaf context for `editor-reset.leaf` (confirm + done states).
    struct EditorResetContext: Encodable {
        let done: Bool
        let next: String
        let currentUser: CurrentUserContext?
    }

    // MARK: - GET /reset-editor

    @Sendable
    func editorResetPage(req: Request) async throws -> Response {
        struct ResetQuery: Content { var next: String? }
        let next = safeEditorResetReturnPath((try? req.query.decode(ResetQuery.self))?.next)
        return try await req.view.render(
            "editor-reset",
            EditorResetContext(done: false, next: next, currentUser: req.currentUserContext)
        ).encodeResponse(for: req)
    }

    // MARK: - POST /reset-editor

    @Sendable
    func performEditorReset(req: Request) async throws -> Response {
        struct ResetForm: Content { var next: String? }
        let next = safeEditorResetReturnPath((try? req.content.decode(ResetForm.self))?.next)
        let response = try await req.view.render(
            "editor-reset",
            EditorResetContext(done: true, next: next, currentUser: req.currentUserContext)
        ).encodeResponse(for: req)
        // Clear cached editor assets, the IndexedDB-backed JupyterLite Drive, and
        // any stale service-worker registration for this origin so the next load
        // boots the kernel clean.  Deliberately omit "cookies": the session must
        // survive so the student stays signed in.
        response.headers.replaceOrAdd(name: "Clear-Site-Data", value: "\"cache\", \"storage\"")
        if let userID = req.auth.get(APIUser.self)?.id {
            req.logger.info("editor_reset_cleared_site_data student=\(userID.uuidString)")
        }
        return response
    }
}

/// Sanitizes a caller-supplied `next` into a safe same-origin redirect path,
/// defaulting to "/".  Rejects protocol-relative ("//host") and absolute
/// ("https://host") URLs so the page can't be abused as an open redirect, and
/// rejects whitespace / control characters so the value is safe to embed in an
/// HTML attribute.  Mirrors the same-origin check in `postLoginRedirect`.
func safeEditorResetReturnPath(_ raw: String?) -> String {
    guard let candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
        !candidate.isEmpty,
        candidate.count <= 512,
        candidate.hasPrefix("/"),
        !candidate.hasPrefix("//"),
        !candidate.contains("://"),
        !candidate.contains("\\"),
        candidate.unicodeScalars.allSatisfy({
            $0 != " " && !CharacterSet.controlCharacters.contains($0)
        })
    else {
        return "/"
    }
    return candidate
}
