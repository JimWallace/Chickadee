// APIServer/Routes/Web/PublishedAssignmentRoutes+Suite.swift
//
// The unified suite-editor endpoint.  GET returns the full reconciled
// author-facing view of the suite list (scripts + families, in manifest
// order, with `family:<id>` tokens re-collapsed in the `dependsOn` field).
// PUT replaces the whole list atomically by delegating to
// `applyPatternFamilies`, which handles validation, zip mutation, and
// manifest rewrite.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    // Suite editor DTOs (SuitePayload / SuiteItemDTO / ScriptDTO /
    // TestSuiteSectionDTO) live in `SuitePayloadDTOs.swift` so the
    // published and draft route collections can share them.

    // MARK: - GET /instructor/:assignmentID/suite

    /// Reconstitutes the author-facing suite items list from the current
    /// persisted manifest.  For each family, collapses `dependsOn` arrays
    /// elsewhere in the manifest that happen to be exactly the family's
    /// enabled-case filename set back into a single `family:<id>` token, so
    /// the editor UI sees the author's high-level intent rather than the
    /// runner-facing expanded form.
    @Sendable
    func getSuite(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        let payload = await buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/:assignmentID/suite

    /// Replaces the full suite list in one atomic operation.  The server
    /// validates + expands + persists via `applyPatternFamilies`, then
    /// returns the reconciled state so the client can replace its local
    /// view without a second round-trip.
    @Sendable
    func putSuite(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)

        let body: SuitePayload
        do { body = try req.content.decode(SuitePayload.self) } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid suite payload: \(error.localizedDescription)")
        }

        try await applySuiteEdit(
            setup: setup, body: body,
            kernelEnvironments: req.application.kernelEnvironments, on: req.db)

        // Re-grade every existing student submission against the edited suite
        // (gated on a real manifest change) and re-kick validation, restoring
        // the v0.4.93 auto-retest that was lost when suite editing moved off
        // the Save button onto this live endpoint.
        await applyContentEditEffects(
            .gradeAffecting, assignment: assignment, setup: setup,
            actingUserID: req.auth.get(APIUser.self)?.id, context: req)

        let payload = await buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/:assignmentID/time-limit

    /// Sets the assignment-wide default per-test execution time limit — the
    /// web twin of the `set_time_limit` MCP tool, sharing its manifest helper
    /// and accepted range. Like that tool this is a grading-environment knob,
    /// not a change to what the tests check, so it deliberately does NOT
    /// close the assignment, re-run validation, or retest submissions
    /// (contrast `putSuite`). Per-test overrides ride the suite payload's
    /// `timeLimitSeconds` entry field instead.
    @Sendable
    func putTimeLimit(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)

        let body: TimeLimitPayload
        do { body = try req.content.decode(TimeLimitPayload.self) } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid time-limit payload: \(error.localizedDescription)")
        }
        guard mcpTimeLimitRange.contains(body.seconds) else {
            throw WebAssignmentError.invalidParameter(
                name: "seconds",
                reason:
                    "seconds must be an integer between \(mcpTimeLimitRange.lowerBound) and "
                    + "\(mcpTimeLimitRange.upperBound) (got \(body.seconds)).")
        }

        let effective = try await setManifestTimeLimitSeconds(
            setup: setup, to: body.seconds, on: req.db)
        return try await TimeLimitPayload(seconds: effective).encodeResponse(for: req)
    }

}

// MARK: - Reconstitution (file-scope so other routes can reuse it)

/// Convenience: full `GET /suite` payload as sorted-keys JSON string.
/// Pass `zipPath` to embed raw-script bodies in the seed (the editor reads
/// them directly instead of a per-file fetch).
func suiteStateJSON(fromManifest manifest: String, zipPath: String? = nil) async -> String {
    let payload = await buildSuitePayload(fromManifest: manifest, zipPath: zipPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload),
        let s = String(data: data, encoding: .utf8)
    else { return #"{"items":[]}"# }
    return s
}

/// Builds the server-rendered section shells the v0.4.98 edit page emits
/// — one `.section-block` per named section (from `manifest.sections`)
/// plus a trailing "Ungrouped" block when any item has no `sectionID`
/// or no sections are defined at all.  The trailing block renders
/// Renders the unified Global Inputs editor rows: both literal
/// `globalVariables` (Slice 1) and `globalExpressions` (Slice 2),
/// pre-serialised so the Leaf template can stuff each value cell into
/// an `<input value="">`.  Literals appear first (in declared order),
/// expressions follow (each pre-fixed with `=` so the editor JS
/// classifies them on load).
///
/// Empty array when the manifest is unparseable or has no inputs.
func globalVariableShellRows(fromManifest manifest: String) -> [SuiteSectionVariableShellRow] {
    guard let props = decodeManifest(fromJSON: manifest)

    else {
        return []
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var rows: [SuiteSectionVariableShellRow] = props.globalVariables.map { v in
        let json = (try? encoder.encode(v.value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return SuiteSectionVariableShellRow(name: v.name, valueJSON: json)
    }
    // Slice 2 expressions — leading `=` marks them as expressions when
    // the editor's `classifyValue` parses each row on load.
    for e in props.globalExpressions {
        rows.append(
            SuiteSectionVariableShellRow(
                name: e.name,
                valueJSON: "= \(e.expression)"
            ))
    }
    return rows
}

/// identically to the pre-sections layout when there are no sections
/// (single unlabelled table), preserving back-compat with legacy
/// assignments.
func suiteSectionShellRows(fromManifest manifest: String) -> [SuiteSectionShellRow] {
    guard let props = decodeManifest(fromJSON: manifest)

    else {
        return [
            SuiteSectionShellRow(
                sectionID: "", name: "", isUngrouped: true,
                variables: [], hasVariables: false)
        ]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var rows: [SuiteSectionShellRow] = props.sections.map { section in
        var vars: [SuiteSectionVariableShellRow] = section.variables.map { v in
            let json = (try? encoder.encode(v.value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return SuiteSectionVariableShellRow(name: v.name, valueJSON: json)
        }
        // Slice 4 — render per-student expressions with the same `=`
        // prefix convention used by the global panel.  The editor JS
        // (`section-inputs-editor.js`) classifies them on load and
        // sends them back as `expressions: [...]` on save.
        for e in section.expressions {
            vars.append(
                SuiteSectionVariableShellRow(
                    name: e.name,
                    valueJSON: "= \(e.expression)"
                ))
        }
        return SuiteSectionShellRow(
            sectionID: section.id, name: section.name,
            isUngrouped: false,
            variables: vars,
            hasVariables: !vars.isEmpty)
    }
    let knownSectionIDs = Set(props.sections.map(\.id))
    let anyUngrouped = props.testSuites.contains { entry in
        guard let sid = entry.sectionID else { return true }
        return !knownSectionIDs.contains(sid)
    }
    if anyUngrouped || props.sections.isEmpty {
        rows.append(
            SuiteSectionShellRow(
                sectionID: "", name: "", isUngrouped: true,
                variables: [], hasVariables: false))
    }
    return rows
}
