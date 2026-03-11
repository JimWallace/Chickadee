// APIServer/Routes/BrowserRunnerRoutes.swift
//
// Session-authenticated endpoint that lets the browser download a test setup
// zip for a browser-graded ("lab") assignment.
//
// The browser runner is submit-triggered: when the student clicks Submit,
// notebook.js calls window.BrowserRunner.runAndSubmit(), which:
//   1. Downloads the test setup zip via GET /api/v1/browser-runner/testsetups/:id/download
//   2. Runs test scripts locally in Pyodide
//   3. POSTs notebook bytes + TestOutcomeCollection to POST /api/v1/submissions/browser-result
//
// The existing /api/v1/testsetups/:id/download endpoint requires instructor+
// privilege, so this session-auth variant is provided for students.

import Vapor
import Fluent
import Core
import Foundation

struct BrowserRunnerRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let br = routes.grouped("api", "v1", "browser-runner")
        br.get("testsetups", ":testSetupID", "download", use: downloadTestSetup)
    }

    // MARK: - GET /api/v1/browser-runner/testsetups/:id/download

    /// Session-authenticated test setup artifact download.
    /// Any authenticated user may download a test setup (same policy as the
    /// instructor-facing GET /api/v1/testsetups/:id/download, but without the
    /// instructor-role requirement).
    @Sendable
    func downloadTestSetup(req: Request) async throws -> Response {
        _ = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup   = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        return try await req.fileio.asyncStreamFile(at: setup.zipPath)
    }
}
