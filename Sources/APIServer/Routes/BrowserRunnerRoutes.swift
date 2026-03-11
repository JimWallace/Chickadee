// APIServer/Routes/BrowserRunnerRoutes.swift
//
// Session-authenticated endpoints that let the browser download a test setup
// zip and its manifest for a browser-graded ("lab") assignment.
//
// The browser runner is submit-triggered: when the student clicks Submit,
// notebook.js calls window.BrowserRunner.runAndSubmit(), which:
//   1. Downloads the test setup zip via GET /api/v1/browser-runner/testsetups/:id/download
//   2. Fetches the manifest JSON via GET /api/v1/browser-runner/testsetups/:id/manifest
//   3. Runs test scripts locally in Pyodide
//   4. POSTs notebook bytes + TestOutcomeCollection to POST /api/v1/submissions/browser-result
//
// The existing /api/v1/testsetups/:id/download endpoint requires instructor+
// privilege, so this session-auth variant is provided for students.
//
// Note: test.properties.json is NOT included in the zip on disk (the native
// runner receives the manifest via the Job struct instead). The manifest
// endpoint serves it directly from the database so the browser runner can
// read the up-to-date gradingMode and testSuites without re-zipping.

import Vapor
import Fluent
import Core
import Foundation

struct BrowserRunnerRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let br = routes.grouped("api", "v1", "browser-runner")
        br.get("testsetups", ":testSetupID", "download",  use: downloadTestSetup)
        br.get("testsetups", ":testSetupID", "manifest",  use: getTestSetupManifest)
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

    // MARK: - GET /api/v1/browser-runner/testsetups/:id/manifest

    /// Returns the test setup manifest (test.properties.json content) as JSON.
    ///
    /// The browser runner uses this instead of reading test.properties.json
    /// from the zip, because the zip on disk does not include that file
    /// (the native runner receives the manifest via the Job struct). This
    /// endpoint always reflects the current database value, including any
    /// grading-mode changes made after the zip was originally uploaded.
    @Sendable
    func getTestSetupManifest(req: Request) async throws -> Response {
        _ = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup   = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers,
                        body: .init(string: setup.manifest))
    }
}
