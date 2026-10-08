// APIServer/Services/SuiteEditing.swift
//
// The suite-list edit and its read-back, shared by the web suite editor and
// the MCP suite tools. Moved out of Routes/Web (#2496), so the MCP tools do
// not depend on the web route layer.

import Core
import Fluent
import Foundation
import Vapor

// Pattern families and notebook checks have no dedicated full-replace editor
// helpers: their writes flow through `applySuiteEdit` (the single PUT /suite
// path).  The standalone `applyPatternFamiliesEdit` /
// `applyNotebookChecksEdit` helpers — and the PUT /families / PUT /checks
// endpoints they backed — were retired in v0.4.227.

/// Translates a `SuitePayload` into `applyPatternFamilies` arguments and
/// applies it.  Used by both `PUT /instructor/:id/suite` and
/// `PUT /instructor/new/draft/suite`.
///
/// Errors:
///   - `.badRequest` for malformed items (missing script payload, missing
///     family payload, unknown kind).
///   - whatever `applyPatternFamilies` throws for validation failures.
func applySuiteEdit(
    setup: APITestSetup,
    body: SuitePayload,
    kernelEnvironments: KernelEnvironments? = nil,
    on db: Database
) async throws {
    var authored: [AuthoredSuiteItem] = []
    var nextFamilies: [PatternFamily] = []
    var nextChecks: [NotebookCheck] = []
    for item in body.items {
        switch item.kind {
        case "script":
            guard let s = item.script else {
                throw WebAssignmentError.invalidParameter(
                    name: "items",
                    reason: "Suite item kind=script is missing `script` payload.")
            }
            authored.append(
                .script(
                    AuthoredRawScript(
                        script: s.script,
                        tier: s.tier,
                        points: s.points,
                        displayName: s.displayName,
                        dependsOn: s.dependsOn,
                        sectionID: item.sectionID,
                        content: s.content,
                        hint: s.hint,
                        timeLimitSeconds: s.timeLimitSeconds,
                        failureDetail: try parseFailureDetail(s.failureDetail, script: s.script)
                    )))
        case "family":
            guard var f = item.family else {
                throw WebAssignmentError.invalidParameter(
                    name: "items",
                    reason: "Suite item kind=family is missing `family` payload.")
            }
            // Allow callers to carry the family's top-level dependsOn in
            // either `family.dependsOn` or `item.dependsOn`; the row-level
            // field wins so the UI can adopt a dep without rebuilding the
            // whole family spec.  Preserves `variables` (added in v0.4.94)
            // — without that an `argVarRefs` reference would fail
            // validation on the next save.
            if let rowDeps = item.dependsOn {
                f = f.replacingDependsOn(rowDeps)
            }
            authored.append(.family(id: f.id, sectionID: item.sectionID))
            nextFamilies.append(f)
        case "check":
            // Notebook-check rows carry their full spec.  As of the
            // suite-save unification (Phase B) `PUT /suite` is authoritative
            // for the whole test-item list — scripts, families, AND checks
            // — so we collect the spec into `nextChecks` (full-replace,
            // symmetric with `nextFamilies`) and stamp the authored
            // position.  The editor always sends every row's current spec
            // (the seed is refreshed after each `PUT /checks` modal save),
            // so a reorder save round-trips check specs unchanged.  The
            // dedicated `PUT /checks` endpoint stays for the check modal.
            guard let c = item.check else {
                throw WebAssignmentError.invalidParameter(
                    name: "items",
                    reason: "Suite item kind=check is missing `check` payload.")
            }
            authored.append(.check(id: c.id, sectionID: item.sectionID))
            nextChecks.append(c)
        default:
            throw WebAssignmentError.invalidParameter(
                name: "items",
                reason: "Unknown suite item kind '\(item.kind)'.")
        }
    }

    // Refuse browser-graded Python scripts whose imports the grading kernel
    // cannot satisfy. Only items that CARRY new content are checked: a reorder
    // or a tier change re-inlines existing files without supplying content, and
    // failing those would make an unrelated save impossible to complete.
    for item in body.items where item.kind == "script" {
        guard let s = item.script, let content = s.content else { continue }
        try await KernelImportGuard.check(
            filename: s.script, content: content, setup: setup, environments: kernelEnvironments)
    }

    // Section CRUD lives on dedicated endpoints (v0.4.98) — pass `nil`
    // so applyPatternFamilies falls through to the manifest's existing
    // sections list.  The client's body may include `sections` for
    // back-compat but we don't act on it here.
    _ = try await applyPatternFamilies(
        to: setup,
        nextFamilies: nextFamilies,
        nextChecks: nextChecks,
        authoredItems: authored,
        sections: nil,
        on: db
    )
}

/// Encodes an `Encodable` payload as a sorted-keys JSON response with
/// `Content-Type: application/json` and the given status.  Used by the
/// PUT endpoints to echo their applied state back to the client.
func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return Response(
        status: status,
        headers: ["Content-Type": "application/json"],
        body: .init(data: data))
}

/// Reads a persisted manifest and builds the author-facing view of the
/// suite list, collapsing fully-expanded family filename sets back into
/// `family:<id>` tokens so the editor sees intent, not plumbing.
func buildSuitePayload(fromManifest manifest: String, zipPath: String? = nil) async -> SuitePayload {
    guard let props = decodeManifest(fromJSON: manifest)

    else {
        return SuitePayload(items: [], sections: [])
    }

    let familyByID = Dictionary(uniqueKeysWithValues: props.patternFamilies.map { ($0.id, $0) })
    let checkByID = Dictionary(uniqueKeysWithValues: props.notebookChecks.map { ($0.id, $0) })
    // The assignment's own language, not Python's. These filenames are matched
    // against the `dependsOn` values already persisted in the manifest, and a
    // persisted dep carries the language's real extension — so computing `.py`
    // names here meant the superset test below never matched on an R, Lua,
    // Octave, C++ or Racket assignment, and the editor showed a family's
    // expanded filenames where every Python assignment showed one `family:<id>`
    // row. No notebook is read: a persisted manifest records its language, and
    // a suite with generated entries has scripts to resolve from either way.
    let language = AssignmentLanguage.resolve(manifest: props) ?? .python
    var familyFilenames: [String: Set<String>] = [:]
    for f in props.patternFamilies {
        familyFilenames[f.id] = Set(
            f.cases
                .filter(\.enabled)
                .map { c in
                    generatedScriptFilename(
                        familyID: f.id,
                        caseKey: c.key,
                        tier: c.resolvedTier(defaults: f.defaults),
                        language: language
                    )
                })
    }

    // Collapse expanded family-filename subsets back into family: tokens.
    func collapseDeps(_ deps: [String]) async -> [String] {
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
            await items.append(
                SuiteItemDTO(
                    kind: "script",
                    script: ScriptDTO(
                        script: entry.script,
                        tier: entry.tier,
                        points: entry.points,
                        displayName: entry.name,
                        dependsOn: collapseDeps(entry.dependsOn),
                        hint: entry.hint,
                        timeLimitSeconds: entry.timeLimitSeconds,
                        failureDetail: entry.failureDetail?.rawValue
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
                let body = await readScriptFromZip(zipPath: zipPath, filename: name)
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

/// Maps a `ScriptDTO.failureDetail` string to the enum: absent or empty means
/// "full" (stored as nil), an unknown token is refused rather than silently
/// dropped, since a dropped setting would show a student the answer the
/// instructor meant to withhold.
func parseFailureDetail(_ raw: String?, script: String) throws -> FailureDetail? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let detail = FailureDetail(rawValue: raw) else {
        throw WebAssignmentError.invalidParameter(
            name: "failureDetail",
            reason:
                "Script \(script): failureDetail must be one of "
                + FailureDetail.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }
    return detail == .full ? nil : detail
}
