// APIServer/MCP/Tools/AuthorScriptTool.swift
//
// Write tool: create or replace a single hand-written test or support file in
// an assignment's test-setup zip, by public ID.  content:write, course-scoped.
//
// This is the raw-script-authoring channel the other write tools deliberately
// omit (update_suite edits metadata only; update_pattern_family edits generated
// cases).  It mirrors the web "New Script" / per-script edit endpoints:
//
//   - A *test* tier (public/release/secret/student) upserts the file AND its
//     suite (manifest) entry through the same `applySuiteEdit` path the suite
//     editor uses, so tier/points/displayName/dependsOn/section all persist and
//     validation re-runs.
//   - The *support* pseudo-tier writes a helper file that is NOT a graded suite
//     entry — importable by tests and by personalization expressions (e.g. a
//     genome→sequence generator) — keeping the shared support directory in sync.
//
// Generated files (pattern-family / notebook-check output) are never editable
// here: those are owned by their family/check and the call is rejected, exactly
// as the web `PUT /scripts/:filename` returns 409.

import Core
import Fluent
import Foundation
import Vapor

struct AuthorScriptTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let filename: String
        let content: String
        /// public/release/secret/student, or "support" for a non-graded helper
        /// file.  When omitted, an existing file keeps its current kind/tier and
        /// a brand-new file defaults to a public test.
        let tier: String?
        let points: Int?
        let displayName: String?
        let dependsOn: [String]?
        let sectionID: String?
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let filename: String
        let tier: String
        /// false for support files (not part of the graded suite).
        let isTest: Bool
        /// true when the file did not previously exist in the setup zip.
        let created: Bool
        /// The assignment's validation status; the edit re-kicks validation
        /// asynchronously, so re-read get_assignment to see it settle.
        let validationStatus: String?
        /// true when this edit closed a previously-open assignment (re-open with
        /// update_assignment once validation passes).
        let assignmentClosed: Bool
    }

    static let name = "author_script"
    static let description =
        "Escape hatch for a hand-written test, plus the normal way to add a non-graded support/helper "
        + "file. For a GRADED test, prefer Chickadee's native check types first: create_pattern_family "
        + "/ update_pattern_family (a function's return value equals / is close to an expected, names a "
        + "type, raises, meets a performance bound, prints expected stdout, or a module variable equals "
        + "a value) and author_notebook_check (DataFrame / Series / array / figure / source-AST / "
        + "variable assertions). Native checks are validated on save, personalize per student, and can "
        + "be read back via get_suite; a raw script is written verbatim (only the async validation run "
        + "catches errors in it) and is opaque to readers. Use a graded tier here only when no pattern "
        + "kind or notebook check fits. "
        + "Create or replace a single hand-written test or support file in an assignment's test "
        + "setup, by its public ID. Provide filename (a bare name, no path separators) and content "
        + "(the full script body). tier is public/release/secret/student for a graded test, or "
        + "\"support\" for a helper file that tests or personalization expressions can import but that "
        + "is not itself graded; omit tier to keep an existing file's kind (new files default to a "
        + "public test). For test tiers you may also set points, displayName, dependsOn (prerequisite "
        + "script names or family:<id> tokens), and sectionID (an existing section). Cannot edit "
        + "pattern-family or notebook-check generated scripts — edit the family/check instead. Saving "
        + "re-runs the assignment's validation and closes the assignment if it was open (re-open with "
        + "update_assignment once validation passes)."

    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object([
                "type": .string("string"),
                "description": .string("The assignment's 6-character public ID."),
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Bare filename with no path separators, e.g. \"secrettest_marker.py\". "
                        + "Python files should start with a `#!/usr/bin/env python3` shebang so "
                        + "extensionless names aren't run as /bin/sh."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string("The full script body, written verbatim into the setup zip."),
            ]),
            "tier": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("public"), .string("release"), .string("secret"),
                    .string("student"), .string("support"),
                ]),
                "description": .string(
                    "Graded tier, or \"support\" for a non-graded helper file. "
                        + "Omit to keep an existing file's kind; new files default to public."),
            ]),
            "points": .object([
                "type": .string("integer"),
                "description": .string("Marks for a test tier (ignored for support). Defaults to 1 on create."),
            ]),
            "displayName": .object([
                "type": .string("string"),
                "description": .string("Friendly name shown in the suite and results (test tiers only)."),
            ]),
            "dependsOn": .object([
                "type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string(
                    "Prerequisite script filenames or family:<id> tokens (test tiers only)."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string(
                    "Existing section id to place a test row into (test tiers only); "
                        + "an unknown id is treated as ungrouped."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("filename"), .string("content")]),
        "additionalProperties": .bool(false),
    ])

    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": .object(["type": .string("string")]),
            "filename": .object(["type": .string("string")]),
            "tier": .object(["type": .string("string")]),
            "isTest": .object(["type": .string("boolean")]),
            "created": .object(["type": .string("boolean")]),
            "validationStatus": .object(["type": .string("string")]),
            "assignmentClosed": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("filename"), .string("tier"),
            .string("isTest"), .string("created"), .string("assignmentClosed"),
        ]),
    ])

    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    // MARK: - Tier resolution

    private enum ResolvedTier {
        case test(TestTier)
        case support

        var isTest: Bool {
            if case .test = self { return true }
            return false
        }

        var wireValue: String {
            switch self {
            case .test(let tier): return tier.rawValue
            case .support: return "support"
            }
        }
    }

    private static func parseTier(_ raw: String) throws -> ResolvedTier {
        if raw == "support" { return .support }
        guard let tier = TestTier(rawValue: raw) else {
            throw MCPToolError.invalidArguments(
                tool: name, detail: "tier must be one of: public, release, secret, student, support.")
        }
        return .test(tier)
    }

    // MARK: - Execute

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard !input.content.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "`content` must not be empty.")
        }
        let cleaned = sanitizeSuiteFilename(input.filename)
        guard !cleaned.isEmpty, cleaned == input.filename else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "filename must be a bare filename with no path separators (got \"\(input.filename)\").")
        }

        guard let assignment = try await assignmentByPublicID(input.assignmentPublicID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "No assignment found with public ID \"\(input.assignmentPublicID)\".")
        }
        try await context.authorizeCourseAccess(assignment.courseID, tool: Self.name)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: context.db) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "The assignment's test setup could not be found.")
        }

        // Never clobber a pattern-family / notebook-check generated script —
        // those are owned by the family/check, mirroring the web 409.
        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: cleaned) {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "\"\(cleaned)\" is generated from pattern family \"\(familyID)\"; edit the family instead.")
        }

        let manifest = setup.decodedManifest()
        let existingTestEntry = manifest?.testSuites.first { $0.script == cleaned }
        let existedInZip = listZipEntries(zipPath: setup.zipPath).contains(cleaned)

        // Resolve the effective kind/tier: explicit input wins; otherwise keep
        // an existing test's tier, treat an existing non-suite file as support,
        // and default a brand-new file to a public test.
        let resolved: ResolvedTier
        if let raw = input.tier {
            resolved = try Self.parseTier(raw)
        } else if let existingTestEntry {
            resolved = .test(existingTestEntry.tier)
        } else if existedInZip {
            resolved = .support
        } else {
            resolved = .test(.pub)
        }

        switch resolved {
        case .support:
            // Demoting a currently-graded test to a support file would orphan
            // its manifest entry, so refuse it here and point at the dedicated
            // tools instead. Promotion (support → test) is fine via the suite
            // path below.
            if existingTestEntry != nil {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "\"\(cleaned)\" is currently a graded test; change its tier with update_suite "
                        + "or delete it before re-authoring it as a support file.")
            }
            try authorSupportFile(
                filename: cleaned, content: input.content, setup: setup, assignment: assignment, context: context)
        case .test(let tier):
            try await authorTestScript(
                filename: cleaned, content: input.content, tier: tier, input: input,
                setup: setup, context: context)
        }

        // Close a currently-open assignment (matching the web Save button) so
        // students can't submit against the not-yet-revalidated suite, then
        // re-kick validation against the new manifest/zip (debounced), mirroring
        // the web suite/script edit handlers.
        let closed = try await closeOpenAssignmentForContentEdit(assignment, on: context.db)
        // Re-grade existing submissions against the edited suite (gated on a real
        // manifest change), the automatic equivalent of the "Retest all" button.
        await retestSubmissionsAfterContentEdit(setup: setup, context: context)
        await scheduleValidationAfterSuiteEdit(req: context.request, assignment: assignment)

        return Output(
            assignmentPublicID: assignment.publicID,
            filename: cleaned,
            tier: resolved.wireValue,
            isTest: resolved.isTest,
            created: !existedInZip,
            validationStatus: assignment.validationStatus,
            assignmentClosed: closed)
    }

    // MARK: - Test-script authoring (suite-payload path)

    private func authorTestScript(
        filename: String, content: String, tier: TestTier, input: Input,
        setup: APITestSetup, context: ToolContext
    ) async throws {
        // Load the full authored suite (script bodies preserved from the zip)
        // so applySuiteEdit rewrites the whole list without dropping the other
        // scripts — exactly the channel UpdateSuiteTool uses.
        var payload = buildSuitePayload(fromManifest: setup.manifest, zipPath: setup.zipPath)
        let normalizedSection = input.sectionID.flatMap { $0.isEmpty ? nil : $0 }
        let displayName = input.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let points = max(0, input.points ?? 1)

        if let idx = payload.items.firstIndex(where: { $0.kind == "script" && $0.script?.script == filename }) {
            // Replace an existing hand-written script. Content + tier always
            // apply; the rest only when the caller supplied them.
            payload.items[idx].script?.content = content
            payload.items[idx].script?.tier = tier
            if input.points != nil { payload.items[idx].script?.points = points }
            if let dn = input.displayName { payload.items[idx].script?.displayName = dn.isEmpty ? nil : dn }
            if let deps = input.dependsOn { payload.items[idx].script?.dependsOn = deps }
            if input.sectionID != nil { payload.items[idx].sectionID = normalizedSection }
        } else {
            // Create a new hand-written script. Insert it adjacent to its
            // section's existing block (or the ungrouped block) so the
            // server-side contiguity check in applyPatternFamilies passes.
            let dto = ScriptDTO(
                script: filename, tier: tier, points: points,
                displayName: displayName, dependsOn: input.dependsOn ?? [],
                content: content, hint: nil)
            let item = SuiteItemDTO(
                kind: "script", script: dto, family: nil, check: nil,
                dependsOn: nil, sectionID: normalizedSection)
            if let lastIdx = payload.items.lastIndex(where: { $0.sectionID == normalizedSection }) {
                payload.items.insert(item, at: payload.items.index(after: lastIdx))
            } else {
                payload.items.append(item)
            }
        }

        do {
            try await applySuiteEdit(setup: setup, body: payload, on: context.db)
        } catch let error as WebAssignmentError {
            throw MCPToolError.from(error, tool: Self.name)
        } catch let error as any AbortError {
            throw MCPToolError.from(error, tool: Self.name)
        }
    }

    // MARK: - Support-file authoring (direct zip write)

    private func authorSupportFile(
        filename: String, content: String, setup: APITestSetup,
        assignment: APIAssignment, context: ToolContext
    ) throws {
        // Inline global + section variables into a `.py` helper (no-op for
        // other extensions or an undecodable manifest), matching the web
        // POST /scripts support path.
        let toWrite: String = {
            guard let manifest = setup.decodedManifest() else { return content }
            return TestScriptVariablePrepender.applyForRawScript(
                filename: filename, content: content, manifest: manifest)
        }()

        do {
            try updateScriptInZip(zipPath: setup.zipPath, filename: filename, content: toWrite)
        } catch {
            throw MCPToolError.executionFailed(
                tool: Self.name, detail: "Failed to write \"\(filename)\" into the setup zip.")
        }

        // Keep the shared support directory (student working-copy symlinks +
        // the synthetic solution.py) in sync, as the web upload path does.
        let testSuiteScripts: Set<String> = {
            guard let props = setup.decodedManifest() else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: assignment.testSetupID,
            testSuiteScripts: testSuiteScripts,
            testSetupsDirectory: context.request.application.testSetupsDirectory)
    }
}
