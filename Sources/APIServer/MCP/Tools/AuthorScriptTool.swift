// APIServer/MCP/Tools/AuthorScriptTool.swift
//
// Write tool: create or replace a single hand-written test or support file in
// an assignment's test-setup zip, by public ID.  content:write, course-scoped.
//
// This is the raw-script-authoring channel the other write tools deliberately
// omit (update_suite edits metadata only; update_pattern_family edits generated
// cases).  It mirrors the web "New Script" / per-script edit endpoints:
//
//   - A *test* tier (see `MCPTierProse`) upserts the file AND its
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
        /// The full file body, inline.  Mutually exclusive with `sourceUrl`;
        /// exactly one of the two must be provided.
        let content: String?
        /// An https URL the server fetches and stores as the file body — for a
        /// data/support file too large to inline faithfully (e.g. a CSV
        /// fixture).  SSRF-guarded (https only, no private/metadata addresses,
        /// no redirects, size-capped); see `SupportFileURLFetcher`.
        let sourceUrl: String?
        /// A `TestTier` raw value, or "support" for a non-graded helper
        /// file.  When omitted, an existing file keeps its current kind/tier and
        /// a brand-new file defaults to a public test.
        let tier: String?
        let points: Int?
        let displayName: String?
        let dependsOn: [String]?
        let sectionID: String?
        /// Per-test execution time limit override (seconds) for a test tier. A
        /// value in 1...600 sets the override; 0 clears it (revert to the
        /// assignment default); absent/null leaves an existing script's
        /// override unchanged and a new script on the assignment default.
        let timeLimitSeconds: Int?
        /// Support files only: mark the file **grader-only** (true) or clear the
        /// mark (false). A grader-only support file still reaches the native
        /// worker (via the zip) but is withheld from every student-facing path —
        /// editor symlinks, the browser-runner download, and the student
        /// support-file download. Use it for answer keys / reserved holdout
        /// data. Requires worker grading (a browser-graded assignment can't keep
        /// a file from the student). Absent/null leaves the current mark
        /// unchanged. Ignored for test tiers.
        let graderOnly: Bool?
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
        + "setup, by its public ID. Provide filename (a bare name, no path separators) and EITHER "
        + "content (the full body inline) OR sourceUrl (an https URL the server fetches — for a "
        + "data/support file too large to inline faithfully, e.g. a CSV fixture; the fetch is "
        + "SSRF-guarded: https only, no private/loopback/metadata addresses, no redirects, size-capped, "
        + "and the body must be UTF-8 text). tier is \(MCPTierProse.slashAlternatives) for a graded test, or "
        + "\"support\" for a helper file that tests or personalization expressions can import but that "
        + "is not itself graded; omit tier to keep an existing file's kind (new files default to a "
        + "public test). For test tiers you may also set points, displayName, dependsOn (prerequisite "
        + "script names or family:<id> tokens), sectionID (an existing section), and timeLimitSeconds "
        + "(a per-test execution time-limit override in seconds, 1–600; 0 clears it so the script uses "
        + "the assignment default). Cannot edit "
        + "pattern-family or notebook-check generated scripts — edit the family/check instead. "
        + "For a support file, set graderOnly:true to withhold it from every student-facing path "
        + "(editor, browser-runner download, support download) while still bundling it for the worker — "
        + "use it for answer keys / reserved holdout data on worker-graded assignments. Saving "
        + "re-runs the assignment's validation and closes the assignment if it was open (re-open with "
        + "update_assignment once validation passes)."

    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Bare filename with no path separators, e.g. \"secrettest_marker.py\". "
                        + "Python files should start with a `#!/usr/bin/env python3` shebang so "
                        + "extensionless names aren't run as /bin/sh."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "The full file body, written verbatim into the setup zip. Provide this OR "
                        + "sourceUrl, not both."),
            ]),
            "sourceUrl": .object([
                "type": .string("string"),
                "description": .string(
                    "An https URL the server downloads and stores as the file body — use for a "
                        + "data/support file too large to inline (e.g. a CSV). The fetch is SSRF-guarded "
                        + "(https only; the host must not resolve to a loopback/private/link-local/"
                        + "cloud-metadata address; redirects are not followed; capped at 8 MB; body must "
                        + "be UTF-8 text). Provide this OR content, not both."),
            ]),
            "tier": MCPSchema.tierEnum(
                TestTierValues.withSupport,
                description: "Graded tier, or \"support\" for a non-graded helper file. "
                    + "Omit to keep an existing file's kind; new files default to public."),
            "points": .object([
                "type": .string("integer"),
                "description": .string("Marks for a test tier (ignored for support). Defaults to 1 on create."),
            ]),
            "displayName": .object([
                "type": .string("string"),
                "description": .string("Friendly name shown in the suite and results (test tiers only)."),
            ]),
            "dependsOn": .object([
                "type": .string("array"), "items": MCPSchema.string,
                "description": .string(
                    "Prerequisite script filenames or family:<id> tokens (test tiers only)."),
            ]),
            "sectionID": .object([
                "type": .string("string"),
                "description": .string(
                    "Existing section id to place a test row into (test tiers only); "
                        + "an unknown id is treated as ungrouped."),
            ]),
            "timeLimitSeconds": .object([
                "type": .string("integer"),
                "description": .string(
                    "Per-test execution time-limit override in seconds for a test tier "
                        + "(\(mcpTimeLimitRange.lowerBound)–\(mcpTimeLimitRange.upperBound)); 0 clears the "
                        + "override (revert to the assignment default set by set_time_limit). Ignored for "
                        + "support files."),
            ]),
            "graderOnly": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Support files only: true marks the file grader-only (reaches the worker via the "
                        + "zip but is withheld from every student-facing path — editor symlinks, "
                        + "browser-runner download, student support-file download); false clears the mark. "
                        + "Use for answer keys / reserved holdout data. Requires worker grading. "
                        + "Absent leaves the current mark unchanged; ignored for test tiers."),
            ]),
        ]),
        // content/sourceUrl are a one-of (validated in execute), so neither is
        // individually required here.
        "required": .array([.string("assignmentPublicID"), .string("filename")]),
        "additionalProperties": .bool(false),
    ])

    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "filename": MCPSchema.string,
            "tier": MCPSchema.string,
            "isTest": MCPSchema.boolean,
            "created": MCPSchema.boolean,
            "validationStatus": MCPSchema.string,
            "assignmentClosed": MCPSchema.boolean,
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
                tool: name, detail: "tier must be one of: \(MCPTierProse.oneOfListWithSupport).")
        }
        return .test(tier)
    }

    // MARK: - Execute

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let cleaned = sanitizeSuiteFilename(input.filename)
        guard !cleaned.isEmpty, cleaned == input.filename else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "filename must be a bare filename with no path separators (got \"\(input.filename)\").")
        }

        // Validate the content/sourceUrl one-of up front (cheap, no I/O); the
        // actual fetch is deferred to `materialize` below, after the call is
        // authorized and the cheap rejections have passed, so we never make an
        // outbound request for a call we are about to refuse.
        let source = try Self.resolveContentSource(input)

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

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

        // Now that the call has cleared the cheap rejections, materialize the
        // body (fetching sourceUrl if that's the source).
        let content = try await Self.materialize(source, context: context)

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
            // A grader-only file is only safe under worker grading — the browser
            // path ships the workspace to the student. Refuse before writing.
            if input.graderOnly == true,
                (setup.decodedManifest()?.effectiveGradingMode ?? .worker) != .worker
            {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "graderOnly requires worker grading, but this assignment is browser-graded. "
                        + "Switch it with set_grading_mode(\"worker\") first.")
            }
            try authorSupportFile(
                filename: cleaned, content: content, setup: setup, assignment: assignment, context: context)
            if let graderOnly = input.graderOnly {
                try await setManifestGraderOnly(
                    setup: setup, filename: cleaned, graderOnly: graderOnly, on: context.db)
            }
        case .test(let tier):
            try await authorTestScript(
                filename: cleaned, content: content, tier: tier, input: input,
                setup: setup, context: context)
        }

        // Close, re-grade, and re-validate (matching the web Save button).
        let finalized = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        return Output(
            assignmentPublicID: assignment.publicID,
            filename: cleaned,
            tier: resolved.wireValue,
            isTest: resolved.isTest,
            created: !existedInZip,
            validationStatus: assignment.validationStatus,
            assignmentClosed: finalized.assignmentClosed)
    }

    // MARK: - Body resolution (inline content or fetched sourceUrl)

    /// Where a file's body comes from: inline `content` or a server-fetched
    /// `sourceUrl`.
    private enum ContentSource {
        case inline(String)
        case remote(url: String)
    }

    /// Validates the `content`/`sourceUrl` one-of and returns the source. Cheap
    /// and side-effect-free (no network) so it can run before authorization.
    private static func resolveContentSource(_ input: Input) throws -> ContentSource {
        let inline = input.content
        let url = input.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (inline?.isEmpty == false, url?.isEmpty == false) {
        case (true, true):
            throw MCPToolError.invalidArguments(
                tool: name, detail: "Provide either `content` or `sourceUrl`, not both.")
        case (false, false):
            throw MCPToolError.invalidArguments(
                tool: name,
                detail: "Provide `content` (the body inline) or `sourceUrl` (an https URL to fetch).")
        case (true, false):
            return .inline(inline ?? "")
        case (false, true):
            return .remote(url: url ?? "")
        }
    }

    /// Produces the file body, fetching `sourceUrl` under the SSRF guard when
    /// the source is remote. Maps a fetch refusal to an MCP tool error.
    private static func materialize(_ source: ContentSource, context: ToolContext) async throws -> String {
        switch source {
        case .inline(let body):
            return body
        case .remote(let url):
            do {
                return try await SupportFileURLFetcher.fetch(urlString: url, on: context.request)
            } catch let error as SupportFileFetchError {
                throw MCPToolError.invalidArguments(tool: name, detail: error.toolDetail)
            } catch {
                throw MCPToolError.executionFailed(
                    tool: name, detail: "Failed to fetch sourceUrl: \(error).")
            }
        }
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
        // Resolve the override: a value in 1...600 sets it; 0 clears it; nil
        // means "leave unchanged on replace / default on create".
        let validatedLimit: Int? = try input.timeLimitSeconds.map { limit in
            limit == 0 ? 0 : try validateTimeLimitSeconds(limit, tool: Self.name, field: "timeLimitSeconds")
        }

        if let idx = payload.items.firstIndex(where: { $0.kind == "script" && $0.script?.script == filename }) {
            // Replace an existing hand-written script. Content + tier always
            // apply; the rest only when the caller supplied them.
            payload.items[idx].script?.content = content
            payload.items[idx].script?.tier = tier
            if input.points != nil { payload.items[idx].script?.points = points }
            if let dn = input.displayName { payload.items[idx].script?.displayName = dn.isEmpty ? nil : dn }
            if let deps = input.dependsOn { payload.items[idx].script?.dependsOn = deps }
            if input.sectionID != nil { payload.items[idx].sectionID = normalizedSection }
            if let validatedLimit {
                payload.items[idx].script?.timeLimitSeconds = validatedLimit == 0 ? nil : validatedLimit
            }
        } else {
            // Create a new hand-written script. Insert it adjacent to its
            // section's existing block (or the ungrouped block) so the
            // server-side contiguity check in applyPatternFamilies passes.
            let dto = ScriptDTO(
                script: filename, tier: tier, points: points,
                displayName: displayName, dependsOn: input.dependsOn ?? [],
                content: content, hint: nil,
                timeLimitSeconds: (validatedLimit == 0 ? nil : validatedLimit))
            let item = SuiteItemDTO(
                kind: "script", script: dto, family: nil, check: nil,
                dependsOn: nil, sectionID: normalizedSection)
            if let lastIdx = payload.items.lastIndex(where: { $0.sectionID == normalizedSection }) {
                payload.items.insert(item, at: payload.items.index(after: lastIdx))
            } else {
                payload.items.append(item)
            }
        }

        try await applySuiteEditMapped(
            setup: setup, body: payload, tool: Self.name,
            kernelEnvironments: context.request.application.kernelEnvironments,
            on: context.db)
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

        try KernelImportGuard.check(
            filename: filename, content: toWrite, setup: setup,
            environments: context.request.application.kernelEnvironments)

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
