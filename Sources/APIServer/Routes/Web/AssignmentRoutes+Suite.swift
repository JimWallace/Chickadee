// APIServer/Routes/Web/AssignmentRoutes+Suite.swift
//
// The unified suite-editor endpoint.  GET returns the full reconciled
// author-facing view of the suite list (scripts + families, in manifest
// order, with `family:<id>` tokens re-collapsed in the `dependsOn` field).
// PUT replaces the whole list atomically by delegating to
// `applyPatternFamilies`, which handles validation, zip mutation, and
// manifest rewrite.

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - DTOs

    /// One row in the unified suite list, in either direction (GET response
    /// or PUT request body).  Array order is authoritative for UI order.
    struct SuiteItemDTO: Content {
        /// "script" or "family".
        var kind: String
        /// Present when kind == "script".
        var script: ScriptDTO?
        /// Present when kind == "family".
        var family: PatternFamily?
        /// Present when kind == "family".  Family-level deps live on the
        /// family spec too, but we echo them here at the row level for
        /// editor-UI convenience.
        var dependsOn: [String]?
        /// Id into `SuitePayload.sections` (both kinds).  Nil = ungrouped.
        var sectionID: String?
    }

    struct ScriptDTO: Content {
        var script: String               // filename
        var tier: TestTier
        var points: Int
        var displayName: String?
        var dependsOn: [String]          // may contain "family:<id>" tokens
    }

    /// Name + opaque id of a single section.  Order of `SuitePayload.sections`
    /// is authoritative for display order in the editor and the student view.
    struct TestSuiteSectionDTO: Content {
        var id: String
        var name: String
    }

    struct SuitePayload: Content {
        var items: [SuiteItemDTO]
        /// Ordered list of sections.  Clients predating v0.4.96 may omit
        /// this field; it decodes to `[]` in that case.  Always populated
        /// on GET responses.
        var sections: [TestSuiteSectionDTO]

        init(items: [SuiteItemDTO], sections: [TestSuiteSectionDTO] = []) {
            self.items = items
            self.sections = sections
        }

        enum CodingKeys: String, CodingKey { case items, sections }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items    = try c.decodeIfPresent([SuiteItemDTO].self,         forKey: .items)    ?? []
            sections = try c.decodeIfPresent([TestSuiteSectionDTO].self,  forKey: .sections) ?? []
        }
    }

    // MARK: - GET /instructor/:assignmentID/suite

    /// Reconstitutes the author-facing suite items list from the current
    /// persisted manifest.  For each family, collapses `dependsOn` arrays
    /// elsewhere in the manifest that happen to be exactly the family's
    /// enabled-case filename set back into a single `family:<id>` token, so
    /// the editor UI sees the author's high-level intent rather than the
    /// runner-facing expanded form.
    @Sendable
    func getSuite(req: Request) async throws -> Response {
        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/:assignmentID/suite

    /// Replaces the full suite list in one atomic operation.  The server
    /// validates + expands + persists via `applyPatternFamilies`, then
    /// returns the reconciled state so the client can replace its local
    /// view without a second round-trip.
    @Sendable
    func putSuite(req: Request) async throws -> Response {
        try requireInstructor(req)
        let (assignment, setup) = try await loadAssignmentAndSetup(req)

        let body: SuitePayload
        do { body = try req.content.decode(SuitePayload.self) }
        catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid suite payload: \(error.localizedDescription)")
        }

        try await applySuiteEdit(setup: setup, body: body, on: req.db)

        // Re-kick validation so the runner picks up the edited manifest.
        // Debounced: a no-op when a pending validation already exists.
        await scheduleValidationAfterSuiteEdit(req: req, assignment: assignment)

        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

}

// MARK: - Reconstitution (file-scope so other routes can reuse it)

/// Reads a persisted manifest and builds the author-facing view of the
/// suite list, collapsing fully-expanded family filename sets back into
/// `family:<id>` tokens so the editor sees intent, not plumbing.
func buildSuitePayload(fromManifest manifest: String) -> AssignmentRoutes.SuitePayload {
    guard let data = manifest.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
        return AssignmentRoutes.SuitePayload(items: [], sections: [])
    }

    let familyByID = Dictionary(uniqueKeysWithValues: props.patternFamilies.map { ($0.id, $0) })
    var familyFilenames: [String: Set<String>] = [:]
    for f in props.patternFamilies {
        familyFilenames[f.id] = Set(f.cases
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
               Set(remaining).isSuperset(of: filenames) {
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
    var items: [AssignmentRoutes.SuiteItemDTO] = []
    var emittedFamilyIDs: Set<String> = []
    for entry in props.testSuites {
        if let fid = entry.generatedBy {
            guard !emittedFamilyIDs.contains(fid), let family = familyByID[fid] else { continue }
            emittedFamilyIDs.insert(fid)
            items.append(AssignmentRoutes.SuiteItemDTO(
                kind: "family",
                script: nil,
                family: family,
                dependsOn: family.dependsOn,
                sectionID: entry.sectionID
            ))
        } else {
            items.append(AssignmentRoutes.SuiteItemDTO(
                kind: "script",
                script: AssignmentRoutes.ScriptDTO(
                    script:      entry.script,
                    tier:        entry.tier,
                    points:      entry.points,
                    displayName: entry.name,
                    dependsOn:   collapseDeps(entry.dependsOn)
                ),
                family: nil,
                dependsOn: nil,
                sectionID: entry.sectionID
            ))
        }
    }

    let sections = props.sections.map {
        AssignmentRoutes.TestSuiteSectionDTO(id: $0.id, name: $0.name)
    }
    return AssignmentRoutes.SuitePayload(items: items, sections: sections)
}

/// Convenience: full `GET /suite` payload as sorted-keys JSON string.
func suiteStateJSON(fromManifest manifest: String) -> String {
    let payload = buildSuitePayload(fromManifest: manifest)
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
    guard let data = manifest.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
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
        rows.append(SuiteSectionVariableShellRow(
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
    guard let data = manifest.data(using: .utf8),
          let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else {
        return [SuiteSectionShellRow(sectionID: "", name: "", isUngrouped: true,
                                      variables: [], hasVariables: false)]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var rows: [SuiteSectionShellRow] = props.sections.map { section in
        let vars: [SuiteSectionVariableShellRow] = section.variables.map { v in
            let json = (try? encoder.encode(v.value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return SuiteSectionVariableShellRow(name: v.name, valueJSON: json)
        }
        return SuiteSectionShellRow(sectionID: section.id, name: section.name,
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
        rows.append(SuiteSectionShellRow(sectionID: "", name: "", isUngrouped: true,
                                          variables: [], hasVariables: false))
    }
    return rows
}
