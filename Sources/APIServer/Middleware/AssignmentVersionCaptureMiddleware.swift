// APIServer/Middleware/AssignmentVersionCaptureMiddleware.swift
//
// Web-side content-version capture (docs/assignment-versioning.md).
//
// The mirror of the MCP arrangement in `MCPVersionCapture.swift`, and for the
// same reason: rather than asking fifteen instructor write handlers to remember
// two bookkeeping calls, capture hangs off the seam they already share —
// `loadAssignmentAndSetupForWrite` registers the setup and seeds its pre-edit
// baseline, and this middleware snapshots what was registered once the response
// comes back successful.
//
// Web saves are versioned even though only MCP can read or restore the history
// today. A history with browser-shaped holes would be worse than no history at
// all: a later restore would silently discard whatever the unrecorded edit did.
//
// Only 2xx responses are snapshotted. A handler that threw or redirected to an
// error page did not persist an edit worth recording, and the dedupe in
// `AssignmentVersionStore.record` absorbs the rest — a save that changed
// nothing writes no row, which is what lets the seam be generous about when it
// fires.

import Fluent
import Foundation
import Vapor

private struct AssignmentVersionCaptureScopeKey: StorageKey {
    typealias Value = AssignmentVersionCaptureScope
}

extension Request {
    var assignmentVersionCapture: AssignmentVersionCaptureScope {
        if let existing = storage[AssignmentVersionCaptureScopeKey.self] { return existing }
        let scope = AssignmentVersionCaptureScope()
        storage[AssignmentVersionCaptureScopeKey.self] = scope
        return scope
    }

    /// Seeds the pre-edit baseline for `setup` and registers it for a snapshot
    /// once this request succeeds.
    ///
    /// Called from the write seam — before the handler has changed anything,
    /// which is the only moment the pre-edit state is still capturable and
    /// therefore the only moment a first-ever edit can be made recoverable.
    /// Best-effort: an instructor's save must not fail because its history
    /// could not be written.
    func beginAssignmentContentEdit(setup: APITestSetup) async {
        await assignmentVersionCapture.begin(
            setup: setup, testSetupsDirectory: application.testSetupsDirectory, logger: logger, on: db)
    }
}

/// Snapshots the content of every setup a successful request resolved for
/// write. A no-op — one storage read — for the overwhelming majority of
/// requests, which register nothing.
struct AssignmentVersionCaptureMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        guard (200..<300).contains(response.status.code) else {
            // Failed or redirected-to-error: nothing persisted worth recording.
            // Drain anyway so a registered setup can't leak into a later
            // request sharing this storage.
            _ = request.assignmentVersionCapture.drain()
            return response
        }
        await capture(on: request)
        return response
    }

    private func capture(on request: Request) async {
        let scope = request.assignmentVersionCapture
        guard !scope.isEmpty else { return }
        await scope.recordRegistered(
            origin: AssignmentVersionOrigin.web(action: Self.action(for: request)),
            actor: request.auth.get(APIUser.self),
            testSetupsDirectory: request.application.testSetupsDirectory,
            logger: request.logger,
            on: request.db)
    }

    /// A short, stable label for what produced the version: the matched route
    /// pattern rather than the concrete URL, so every assignment's history
    /// reads `web:PUT /instructor/:assignmentID/suite` instead of embedding a
    /// public ID that is already on the row.
    static func action(for request: Request) -> String {
        let path = request.route.map { "/" + $0.path.map(\.description).joined(separator: "/") }
        return "\(request.method.rawValue) \(path ?? request.url.path)"
    }
}
