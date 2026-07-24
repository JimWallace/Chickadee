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

        // Gate on effective-open (enrollment + open/visible), not enrollment
        // alone: a student must not be able to pull the test scripts of a
        // closed, not-yet-opened, or staff-only (preview) assignment by guessing
        // its testSetupID. requireOpenStudentAssignment throws .closed (403) for a
        // gated student and bypasses for staff. It returns nil only when no
        // assignment owns the setup — then there is no hidden assignment to
        // protect, so fall back to the plain enrollment check.
        if try await requireOpenStudentAssignment(for: setupID, user: caller, on: req) == nil {
            try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
        }

        // Grader-only files (answer keys, reserved holdout sets) must never reach
        // a browser-graded student — the whole stored zip is streamed into the
        // Pyodide FS, which a determined student can inspect. Stream a filtered
        // copy with those entries removed. The common case declares none (a
        // grader-only file forces worker grading, see docs/datasets.md), so the
        // empty case takes the no-copy streaming fast path.
        let graderOnly = setup.decodedManifest()?.graderOnlyFiles ?? []
        guard !graderOnly.isEmpty else {
            return try await req.fileio.asyncStreamFile(at: setup.zipPath)
        }
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ck-browser-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let tempZip = tempDir.appendingPathComponent("setup.zip").path
        try fm.copyItem(atPath: setup.zipPath, toPath: tempZip)
        // writes:[:] — pure deletion of the grader-only entries from the copy.
        try applyScriptChangesToZip(zipPath: tempZip, writes: [:], deletions: graderOnly)
        let filtered = try Data(contentsOf: URL(fileURLWithPath: tempZip))
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "zip")
        return Response(status: .ok, headers: headers, body: .init(data: filtered))
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

        // Effective-open gate (see downloadTestSetup): the manifest carries the
        // full testSuites list, so the same hidden-assignment leak applies.
        if try await requireOpenStudentAssignment(for: setupID, user: caller, on: req) == nil {
            try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
        }

        // Withhold the *names* of grader-only support files (option B —
        // docs/datasets.md) from the student-facing manifest. Their contents are
        // already withheld at every download path (#1055); this closes the
        // residual leak where `graderOnlyFiles` still named the holdout /
        // answer-key files in the JSON served to the student's browser.
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json; charset=utf-8")
        return Response(
            status: .ok, headers: headers,
            body: .init(string: manifestWithGraderOnlyFilesStripped(setup.manifest)))
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

        // Effective-open gate (enrollment + open/visible): prevents a student
        // from fetching the per-student resolved personalization values — which
        // can encode solution-derived expected answers — for a closed,
        // not-yet-opened, or preview assignment. requireOpenStudentAssignment
        // throws .closed (403) for a gated student and bypasses for staff; it
        // returns nil only when no assignment owns the setup, in which case there
        // is nothing personalized to resolve — fall back to the enrollment check
        // and return the empty seed (mirroring the worker leaving it unset).
        guard let assignment = try await requireOpenStudentAssignment(for: setupID, user: caller, on: req)
        else {
            try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)
            return BrowserRunnerSeedResponse(seed: nil, personalizedInputs: nil, personalizedFiles: nil)
        }
        guard let userID = caller.id, let assignmentID = assignment.id else {
            return BrowserRunnerSeedResponse(seed: nil, personalizedInputs: nil, personalizedFiles: nil)
        }

        let seed = try await AssignmentSeedStore.ensureSeed(
            userID: userID, assignmentID: assignmentID, on: req.db)

        // Resolve per-student personalization inputs (issue #461) the same way
        // the worker does — via the shared `gradingInputs` helper — so a
        // browser-graded submission binds the same values a worker would.
        var personalizedInputs: [String: String]?
        var personalizedFiles: [String: String]?
        if let manifest = setup.decodedManifest() {
            let sharedDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
            personalizedInputs = await PersonalizationSubstitution.gradingInputs(
                manifest: manifest, seedHex: seed,
                supportFilesDirectory: sharedDir,
                language: AssignmentLanguage.resolve(manifest: manifest))
            // Resolve per-student dataset slices (Phase 1 datasets) — returns nil when
            // the manifest declares no datasets, which is the common case.
            personalizedFiles = DatasetResolver.resolve(
                manifest: manifest, seedHex: seed, sourceDirectory: sharedDir)
        }
        return BrowserRunnerSeedResponse(
            seed: seed, personalizedInputs: personalizedInputs,
            personalizedFiles: personalizedFiles)
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
    /// Per-student dataset file contents (CSV slices), keyed by filename.
    /// The browser writes these into the Pyodide FS before tests run,
    /// overwriting the full-source version from the test-setup zip so each
    /// student's code sees only their own slice. Nil when no datasets are
    /// declared (the common case — existing assignments are unaffected).
    let personalizedFiles: [String: String]?
}

/// Returns the manifest JSON with the `graderOnlyFiles` array blanked to `[]`,
/// so the student-facing browser manifest endpoint doesn't leak the *names* of
/// reserved holdout / answer-key support files (option B — `docs/datasets.md`).
/// Their contents are already withheld at every download path (#1055); this
/// closes the residual name leak in the manifest the browser fetches.
///
/// Strict no-op — the input is returned byte-for-byte — when there is nothing
/// to strip: the key is absent, already empty, or the body isn't a JSON object.
/// Only when grader-only names are actually present is the JSON rewritten, and
/// then only the `graderOnlyFiles` key changes; every other field is preserved.
func manifestWithGraderOnlyFilesStripped(_ manifest: String) -> String {
    guard
        let data = manifest.data(using: .utf8),
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let existing = object["graderOnlyFiles"] as? [Any], !existing.isEmpty
    else {
        return manifest
    }
    object["graderOnlyFiles"] = [String]()
    guard
        let reencoded = try? JSONSerialization.data(withJSONObject: object),
        let stripped = String(data: reencoded, encoding: .utf8)
    else {
        return manifest
    }
    return stripped
}
