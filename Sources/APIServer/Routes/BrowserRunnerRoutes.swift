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
// Access is gated to users enrolled in the course that owns the test setup
// (or instructor/admin users, who are implicitly granted access).
//
// Note: test.properties.json is NOT included in the zip on disk (the native
// runner receives the manifest via the Job struct instead). The manifest
// endpoint serves it directly from the database so the browser runner can
// read the up-to-date gradingMode and testSuites without re-zipping.

import Core
import Fluent
import Foundation
import Vapor

struct BrowserRunnerRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let br = routes.grouped("api", "v1", "browser-runner")
        br.get("testsetups", ":testSetupID", "download", use: downloadTestSetup)
        br.get("testsetups", ":testSetupID", "manifest", use: getTestSetupManifest)
        br.get("testsetups", ":testSetupID", "seed", use: getAssignmentSeed)
    }

    // MARK: - GET /api/v1/browser-runner/testsetups/:id/download

    /// Session-authenticated test setup artifact download.
    /// Restricted to users enrolled in the course that owns the test setup,
    /// plus instructors and admins.
    @Sendable
    func downloadTestSetup(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
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
        let caller = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json; charset=utf-8")
        return Response(
            status: .ok, headers: headers,
            body: .init(string: setup.manifest))
    }

    // MARK: - GET /api/v1/browser-runner/testsetups/:id/seed

    /// Returns the per-(student, assignment) personalization seed the browser
    /// runner injects into Pyodide as `CHICKADEE_ASSIGNMENT_SEED`.
    ///
    /// Personalization parity: the native worker resolves this exact seed in
    /// `WorkerJobRoutes.buildJobPayload` via `AssignmentSeedStore.ensureSeed`
    /// and injects it into the test subprocess (`RunnerDaemon+JobProcessing`).
    /// Browser grading had no equivalent, so any test reading the seed saw
    /// nothing in-browser. This endpoint calls the SAME `ensureSeed` — keyed by
    /// the same `(userID, assignmentID)` that also backs notebook substitution —
    /// so the browser, the worker backstop, and the student's notebook all share
    /// one seed.
    ///
    /// Returns `{ "seed": null }` when the caller has no id or no assignment
    /// owns the setup — mirroring the worker, which leaves the seed unset in
    /// those cases (a non-personalized grade is unaffected by the missing var).
    @Sendable
    func getAssignmentSeed(req: Request) async throws -> BrowserRunnerSeedResponse {
        let caller = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        // A test setup belongs to a single assignment (1:1 via test_setup_id),
        // matching how the worker resolves the assignment for a claimed job.
        guard
            let userID = caller.id,
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$testSetupID == setupID)
                .first(),
            let assignmentID = assignment.id
        else {
            return BrowserRunnerSeedResponse(seed: nil, personalizedInputs: nil)
        }

        let seed = try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: req.db)

        // Resolve per-student personalization inputs (issue #461) the same way
        // the worker does — via the shared `gradingInputs` helper — so a
        // browser-graded submission binds the same values a worker would.
        var personalizedInputs: [String: String]?
        if let manifest = setup.decodedManifest() {
            personalizedInputs = await PersonalizationSubstitution.gradingInputs(
                manifest: manifest, seedHex: seed,
                supportFilesDirectory: req.application.testSetupsDirectory + "shared/\(setupID)/")
        }
        return BrowserRunnerSeedResponse(seed: seed, personalizedInputs: personalizedInputs)
    }

}

/// JSON body for the browser-runner seed endpoint.
struct BrowserRunnerSeedResponse: Content {
    let seed: String?
    /// Per-student personalization input values (Python literals), keyed by
    /// name — the `=` expressions resolved for this student's seed. The browser
    /// writes these to `_ck_inputs.py` so generated pattern-family scripts can
    /// load per-student args / expected. Nil when there are none (issue #461).
    let personalizedInputs: [String: String]?
}
