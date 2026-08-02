// APIServer/MCP/Tools/DeleteSupportFileTool.swift
//
// Write tool: remove one non-graded support/data file from an assignment's
// test-setup zip.  content:write, course-scoped.  The counterpart to
// author_script(tier: "support"), which could create and replace a support file
// but never remove one — the only way to retire a support file through MCP was
// to overwrite it with a stub, leaving a dead entry in the zip that students
// could still download.
//
// Deliberately narrow: this deletes *support* files only.  A graded suite row
// (hand-written test, pattern-family case, notebook check) is owned by
// delete_suite_item / the family / the check, and reserved setup members
// (the manifest, the starter and solution notebooks) are structural — deleting
// any of them through this door would corrupt the setup, so each is refused
// with a pointer at the right tool.
//
// Removing the file also drops any `graderOnlyFiles` / `datasets` manifest
// marks that named it, so a later file of the same name doesn't silently
// inherit the old marks.

import Core
import Fluent
import Foundation
import Vapor

struct DeleteSupportFileTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Bare support filename to remove (from get_support_files).
        let filename: String
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let removed: String
        /// Support files left in the setup after the removal.
        let remainingSupportFileCount: Int
        /// true when the removal also cleared a graderOnly / dataset mark.
        let clearedManifestMarks: Bool
        let validationStatus: String?
        /// true when this edit closed a previously-open (or preview) assignment.
        let assignmentClosed: Bool
    }

    static let name = "delete_support_file"
    static let description =
        "Remove one non-graded support/data file from an assignment's test setup, by public ID + "
        + "filename (names come from get_support_files). Use it to retire a helper module, a stale "
        + "CSV fixture, or a file left behind by earlier content — overwriting it with a stub is no "
        + "longer necessary. Support files only: a graded test, a pattern-family case, or a notebook "
        + "check is refused (use delete_suite_item, or edit the family/check), and so are the "
        + "reserved setup members test.properties.json / assignment.ipynb / solution.ipynb. Any "
        + "graderOnly or per-student dataset mark naming the file is cleared with it. Saving "
        + "re-packs the setup zip, re-syncs the shared support directory (student symlinks to the "
        + "file disappear), closes the assignment if it was open (reported as `assignmentClosed`; "
        + "re-open with update_assignment once validation passes), and re-runs validation — which "
        + "will fail if a remaining test still sources the file, so check get_suite first."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Bare support filename to remove, no path separators (from get_support_files)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("filename")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "removed": MCPSchema.string,
            "remainingSupportFileCount": MCPSchema.integer,
            "clearedManifestMarks": MCPSchema.boolean,
            "validationStatus": MCPSchema.string,
            "assignmentClosed": MCPSchema.boolean,
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("removed"),
            .string("remainingSupportFileCount"), .string("clearedManifestMarks"),
            .string("assignmentClosed"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    /// Structural members of a test setup. None is a support file, and removing
    /// any would corrupt the setup rather than tidy it.
    static let reservedFilenames: Set<String> = [
        "test.properties.json", "assignment.ipynb", "solution.ipynb",
    ]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let cleaned = sanitizeSuiteFilename(input.filename)
        guard !cleaned.isEmpty, cleaned == input.filename else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail:
                    "filename must be a bare filename with no path separators (got \"\(input.filename)\").")
        }

        guard !Self.reservedFilenames.contains(cleaned) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "\"\(cleaned)\" is a reserved part of the test setup, not a support file. "
                    + "Edit it with update_notebook / update_solution, or the suite tools.")
        }

        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .ta)

        // A graded row is owned by the suite tools; point at the right one
        // rather than tearing the file out from under its manifest entry.
        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: cleaned) {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "\"\(cleaned)\" is generated from pattern family \"\(familyID)\"; "
                    + "remove the family with delete_suite_item(familyID: \"\(familyID)\") instead.")
        }
        let manifest = setup.decodedManifest()
        if manifest?.testSuites.contains(where: { $0.script == cleaned }) == true {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "\"\(cleaned)\" is a graded test, not a support file. Remove it with "
                    + "delete_suite_item(script: \"\(cleaned)\").")
        }

        guard listZipEntries(zipPath: setup.zipPath).contains(cleaned) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No support file \"\(cleaned)\" in this test setup (see get_support_files).")
        }

        do {
            try removeScriptFromZip(zipPath: setup.zipPath, filename: cleaned)
        } catch {
            throw MCPToolError.executionFailed(
                tool: Self.name, detail: "Failed to remove \"\(cleaned)\" from the setup zip.")
        }

        // Drop any manifest marks that named the file, so a future file reusing
        // the name doesn't inherit them.
        let clearedMarks = try await Self.clearManifestMarks(
            setup: setup, filename: cleaned, on: context.db)

        // Re-sync the shared support directory: it is wiped and re-extracted
        // from the zip, so the removed file (and student symlinks to it) go too.
        let testSuiteScripts: Set<String> = {
            guard let props = setup.decodedManifest() else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: assignment.testSetupID,
            testSuiteScripts: testSuiteScripts,
            testSetupsDirectory: context.request.application.testSetupsDirectory)

        // Close, re-grade, and re-validate (matching the web Save button). A
        // test that still sources the deleted file surfaces here as a failed
        // validation rather than as a surprise at submission time.
        let finalized = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)

        // Count with get_support_files' own predicate so the number a caller
        // gets back matches the list they'd read next.
        let remaining = listZipEntries(zipPath: setup.zipPath).filter {
            !testSuiteScripts.contains($0) && !GetSupportFilesTool.reservedNames.contains($0)
        }

        return Output(
            assignmentPublicID: assignment.publicID,
            removed: cleaned,
            remainingSupportFileCount: remaining.count,
            clearedManifestMarks: clearedMarks,
            validationStatus: assignment.validationStatus,
            assignmentClosed: finalized.assignmentClosed)
    }

    /// Removes `filename` from the manifest's `graderOnlyFiles` and `datasets`
    /// lists. Returns true when either actually changed.
    private static func clearManifestMarks(
        setup: APITestSetup, filename: String, on db: any Database
    ) async throws -> Bool {
        let dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any]
        let wasGraderOnly = ((dict?["graderOnlyFiles"] as? [String]) ?? []).contains(filename)
        let wasDataset = ((dict?["datasets"] as? [[String: Any]]) ?? []).contains {
            ($0["filename"] as? String) == filename
        }
        guard wasGraderOnly || wasDataset else { return false }

        try await mutateManifest(setup: setup, on: db) { dict in
            if wasGraderOnly {
                var files = (dict["graderOnlyFiles"] as? [String]) ?? []
                files.removeAll { $0 == filename }
                dict["graderOnlyFiles"] = files
            }
            if wasDataset {
                var specs = (dict["datasets"] as? [[String: Any]]) ?? []
                specs.removeAll { ($0["filename"] as? String) == filename }
                if specs.isEmpty {
                    dict.removeValue(forKey: "datasets")
                } else {
                    dict["datasets"] = specs
                }
            }
        }
        return true
    }
}
