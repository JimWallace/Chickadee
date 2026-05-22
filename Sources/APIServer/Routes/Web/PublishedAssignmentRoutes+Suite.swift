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
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/:assignmentID/suite

    /// Replaces the full suite list in one atomic operation.  The server
    /// validates + expands + persists via `applyPatternFamilies`, then
    /// returns the reconciled state so the client can replace its local
    /// view without a second round-trip.
    @Sendable
    func putSuite(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetup(req)

        let body: SuitePayload
        do { body = try req.content.decode(SuitePayload.self) } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid suite payload: \(error.localizedDescription)")
        }

        try await applySuiteEdit(setup: setup, body: body, on: req.db)

        // Re-kick validation so the runner picks up the edited manifest.
        // Debounced: a no-op when a pending validation already exists.
        await scheduleValidationAfterSuiteEdit(req: req, assignment: assignment)

        let payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        return try await payload.encodeResponse(for: req)
    }

}

// MARK: - Reconstitution (file-scope so other routes can reuse it)

/// Reads a persisted manifest and builds the author-facing view of the
/// suite list, collapsing fully-expanded family filename sets back into
/// `family:<id>` tokens so the editor sees intent, not plumbing.
func buildSuitePayload(fromManifest manifest: String, zipPath: String? = nil) -> SuitePayload {
    guard let props = decodeManifest(fromJSON: manifest)

    else {
        return SuitePayload(items: [], sections: [])
    }

    let familyByID = Dictionary(uniqueKeysWithValues: props.patternFamilies.map { ($0.id, $0) })
    let checkByID = Dictionary(uniqueKeysWithValues: props.notebookChecks.map { ($0.id, $0) })
    var familyFilenames: [String: Set<String>] = [:]
    for f in props.patternFamilies {
        familyFilenames[f.id] = Set(
            f.cases
                .filter(\.enabled)
                .map { c in
                    generatedScriptFilename(
                        familyID: f.id,
                        caseKey: c.key,
                        tier: c.resolvedTier(defaults: f.defaults)
                    )
                })
    }

    // Collapse expanded family-filename subsets back into family: tokens.
    func collapseDeps(_ deps: [String]) -> [String] {
        var remaining = deps
        var collapsed: [String] = []
        for (fid, filenames) in familyFilenames {
            if !filenames.isEmpty,
                Set(remaining).isSuperset(of: filenames)
            {
                remaining.removeAll { filenames.contains($0) }
                collapsed.append(familyDepToken(fid))
            }
        }
        return remaining + collapsed
    }

    // Walk testSuites in order, emitting one item per script or, on the
    // first generated entry for a family, one family row.  Family rows'
    // `dependsOn` comes from the PatternFamily spec (already in author
    // form) rather than from the expanded per-case entries.  Each row
    // carries the underlying entry's `sectionID` so the client can
    // rebuild its grouped view.
    var items: [SuiteItemDTO] = []
    var emittedFamilyIDs: Set<String> = []
    var emittedCheckIDs: Set<String> = []
    for entry in props.testSuites {
        if let fid = entry.generatedBy {
            guard !emittedFamilyIDs.contains(fid), let family = familyByID[fid] else { continue }
            emittedFamilyIDs.insert(fid)
            items.append(
                SuiteItemDTO(
                    kind: "family",
                    script: nil,
                    family: family,
                    check: nil,
                    dependsOn: family.dependsOn,
                    sectionID: entry.sectionID
                ))
        } else if let cid = entry.generatedByCheck {
            guard !emittedCheckIDs.contains(cid), let check = checkByID[cid] else { continue }
            emittedCheckIDs.insert(cid)
            items.append(
                SuiteItemDTO(
                    kind: "check",
                    script: nil,
                    family: nil,
                    check: check,
                    dependsOn: check.dependsOn,
                    sectionID: entry.sectionID
                ))
        } else {
            items.append(
                SuiteItemDTO(
                    kind: "script",
                    script: ScriptDTO(
                        script: entry.script,
                        tier: entry.tier,
                        points: entry.points,
                        displayName: entry.name,
                        dependsOn: collapseDeps(entry.dependsOn),
                        hint: entry.hint
                    ),
                    family: nil,
                    check: nil,
                    dependsOn: nil,
                    sectionID: entry.sectionID
                ))
        }
    }

    // When a zip path is supplied, fill in each raw script's body so the
    // payload carries the complete declarative state (the editor seed and
    // `GET /suite` both want this; pure-manifest callers pass nil and get
    // metadata-only script rows). Generated family/check files are derived
    // from their specs, so only `kind == "script"` rows need a body.
    if let zipPath {
        for i in items.indices where items[i].kind == "script" {
            if let name = items[i].script?.script,
                let body = readScriptFromZip(zipPath: zipPath, filename: name)
            {
                items[i].script?.content = body
            }
        }
    }

    let sections = props.sections.map {
        TestSuiteSectionDTO(id: $0.id, name: $0.name)
    }
    return SuitePayload(items: items, sections: sections)
}

/// Convenience: full `GET /suite` payload as sorted-keys JSON string.
/// Pass `zipPath` to embed raw-script bodies in the seed (the editor reads
/// them directly instead of a per-file fetch).
func suiteStateJSON(fromManifest manifest: String, zipPath: String? = nil) -> String {
    let payload = buildSuitePayload(fromManifest: manifest, zipPath: zipPath)
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
