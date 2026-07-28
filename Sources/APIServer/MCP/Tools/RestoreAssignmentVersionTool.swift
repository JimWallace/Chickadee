// APIServer/MCP/Tools/RestoreAssignmentVersionTool.swift
//
// Write tool: put an assignment's content back to a recorded version
// (docs/assignment-versioning.md). The recovery half of the feature — the
// reason the snapshots exist.
//
// History stays LINEAR and APPEND-ONLY. A restore does not rewind the counter
// or delete anything: it writes the restored content as a NEW version stamped
// `restore:<n>`, so the restore is itself recorded, itself undoable, and the
// timeline still reads as what happened in the order it happened.
//
// Content only. The manifest, the setup-zip files, and the starter notebook go
// back; the title, due date, visibility, course section, and BrightSpace
// mapping do not. A recovery action must never silently reopen an assignment or
// move a deadline students have already seen, so the response reports the
// snapshot's metadata for the human to reapply deliberately if they want it.
//
// A restore changes what is graded, so it runs the standard content-edit
// chokepoint (`finalizeContentEdit`): the assignment closes if it was open,
// existing submissions are re-queued against the restored suite, and validation
// re-runs. The response reports both, because "I restored version 3" and "I
// just re-graded 240 submissions" are the same action and the agent should say
// so.

import Core
import Fluent
import Foundation

struct RestoreAssignmentVersionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// The version to restore, from list_assignment_versions.
        let version: Int
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// The version that was restored.
        let restoredFromVersion: Int
        /// The new version recorded by this restore.
        let newVersion: Int
        let filesRestored: Int
        let notebookRestored: Bool
        /// True when the restore closed a previously-open assignment.
        let assignmentClosed: Bool
        /// Existing submissions re-queued to re-grade against the restored suite.
        let submissionsRequeued: Int
        /// True when the restored content already matched the live content, so
        /// nothing changed and no new version was written.
        let alreadyCurrent: Bool
        /// The title the assignment had at the restored version, when it differs
        /// from the current one. Metadata is NOT restored; this is reported so a
        /// human can reapply it deliberately.
        let titleAtVersion: String?
    }

    static let name = "restore_assignment_version"
    static let description =
        "Restore an assignment's content to a recorded version: its manifest, test-setup files, and "
        + "starter notebook are put back as they were. Use it to undo a bad edit — read the version "
        + "first with get_assignment_version to confirm it is the one you want. History is "
        + "append-only: the restore is recorded as a NEW version (nothing is deleted, and the "
        + "restore is itself undoable). CONTENT ONLY — the title, due date, and visibility are left "
        + "alone, so a restore can never reopen an assignment or move a deadline. Like any content "
        + "edit it CLOSES a currently-open assignment, RE-GRADES every existing submission against "
        + "the restored suite, and re-runs validation; the response reports how many submissions "
        + "were re-queued. Re-open with update_assignment(visibility:\"open\") once validation "
        + "passes. Requires the instructor role in the assignment's course."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "version": .object([
                "type": .string("integer"),
                "description": .string(
                    "Version number to restore, from list_assignment_versions."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("version")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "restoredFromVersion": MCPSchema.integer,
            "newVersion": MCPSchema.integer,
            "filesRestored": MCPSchema.integer,
            "notebookRestored": MCPSchema.boolean,
            "assignmentClosed": MCPSchema.boolean,
            "submissionsRequeued": MCPSchema.integer,
            "alreadyCurrent": MCPSchema.boolean,
            "titleAtVersion": .object(["type": .array([.string("string"), .string("null")])]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("restoredFromVersion"), .string("newVersion"),
            .string("filesRestored"), .string("assignmentClosed"), .string("alreadyCurrent"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        // Instructor-only: a restore re-grades every submission on the setup,
        // which is an assignment-lifecycle action, not routine content editing.
        // The seam also seeds the pre-restore baseline, so the state being
        // replaced is itself recoverable.
        let (assignment, setup) = try await context.authorizedAssignmentAndSetupForWrite(
            publicID: input.assignmentPublicID, tool: Self.name, atLeast: .instructor)
        let setupID = setup.id ?? ""

        let target = try await GetAssignmentVersionTool.requireVersion(
            setupID: setupID, number: input.version, tool: Self.name, on: context.mainDB)

        let directory = context.request.application.testSetupsDirectory
        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: directory)
        let fileMap = target.decodedFileMap()

        // Nothing to do when the target already IS the live content. Reported
        // rather than silently succeeding: an agent that restored the wrong
        // version needs to know its call changed nothing, not infer it.
        let live = try await AssignmentVersionSnapshotBuilder.build(setup: setup, blobs: blobs)
        guard live.snapshotHash != target.snapshotHash else {
            return Output(
                assignmentPublicID: input.assignmentPublicID,
                restoredFromVersion: target.versionNumber,
                newVersion: target.versionNumber,
                filesRestored: fileMap.count,
                notebookRestored: false,
                assignmentClosed: false,
                submissionsRequeued: 0,
                alreadyCurrent: true,
                titleAtVersion: nil)
        }

        try Self.materialize(
            target: target, fileMap: fileMap, setup: setup, blobs: blobs,
            testSetupsDirectory: directory)
        try await setup.save(on: context.db)

        // Re-derive everything downstream of the zip: the shared support-file
        // directory the runner and personalization read, and the generated
        // solution.py. Skipping this would leave the previous version's support
        // files on disk beside the restored suite.
        Self.rederive(setup: setup, testSetupsDirectory: directory)

        let closed = try await finalizeContentEdit(
            assignment: assignment, setup: setup, context: context, retest: true)
        let requeued = try await Self.requeuedCount(setupID: setupID, on: context.mainDB)

        // Record explicitly so the row carries `restore:<n>` and
        // `restoredFromVersion` rather than the generic `mcp:<tool>` origin the
        // dispatcher's automatic capture would stamp. That capture still runs
        // afterwards and dedupes to a no-op, since the content now matches.
        let actor = try? await context.requireEligibleSubject(tool: Self.name)
        let outcome = try await AssignmentVersionStore.record(
            setup: setup,
            request: AssignmentVersionRequest(
                origin: AssignmentVersionOrigin.restore(of: target.versionNumber),
                summary: "restored version \(target.versionNumber)",
                restoredFromVersion: target.versionNumber,
                actor: actor),
            testSetupsDirectory: directory,
            on: context.mainDB)

        return Output(
            assignmentPublicID: input.assignmentPublicID,
            restoredFromVersion: target.versionNumber,
            newVersion: outcome.version ?? target.versionNumber,
            filesRestored: fileMap.count,
            notebookRestored: target.notebookHash != nil,
            assignmentClosed: closed,
            submissionsRequeued: requeued,
            alreadyCurrent: false,
            titleAtVersion: nil)
    }

    // MARK: - Materialization

    /// Rebuilds the setup's zip, notebook, and manifest from `target`.
    ///
    /// The zip is rebuilt from an empty directory and the stale archive deleted
    /// first: `zip -r` ADDS to an existing archive, so repacking in place would
    /// leave files the restored version had deleted sitting in the suite —
    /// every other repack site in the codebase removes first for the same
    /// reason.
    private static func materialize(
        target: APIAssignmentVersion,
        fileMap: [String: String],
        setup: APITestSetup,
        blobs: AssignmentVersionBlobStore,
        testSetupsDirectory: String
    ) throws {
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("chickadee-version-restore-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }

        for (path, hash) in fileMap {
            try blobs.materialize(hash, to: workDir.appendingPathComponent(path))
        }
        try? fileManager.removeItem(atPath: setup.zipPath)
        try repackZipFromDirectory(zipPath: setup.zipPath, sourceDir: workDir)

        if let notebookHash = target.notebookHash {
            let path =
                setup.notebookPath ?? (testSetupsDirectory + "\(setup.id ?? "unknown").ipynb")
            try blobs.materialize(notebookHash, to: URL(fileURLWithPath: path))
            setup.notebookPath = path
        }
        // A snapshot with no notebook leaves the current one in place rather
        // than deleting it: the notebook predates versioning on older setups,
        // and destroying it to match a snapshot that never captured one would
        // lose content the restore was never asked to touch.

        setup.manifest = target.manifest
    }

    /// Re-runs the derivations that hang off the zip's contents.
    private static func rederive(setup: APITestSetup, testSetupsDirectory: String) {
        let setupID = setup.id ?? ""
        let props = setup.decodedManifest()
        let scripts = Set((props?.testSuites ?? []).map(\.script))
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: setupID,
            testSuiteScripts: scripts,
            testSetupsDirectory: testSetupsDirectory)

        if let solution = extractZipEntry(zipPath: setup.zipPath, entryName: "solution.ipynb") {
            SolutionNotebookExtractor.writeSolutionPy(
                notebookData: solution,
                sharedDirectory: testSetupsDirectory + "shared/\(setupID)/",
                overwrite: true)
        }
    }

    /// How many of the setup's submissions are now queued to re-grade. Read
    /// after `finalizeContentEdit` so the number reflects what the retest
    /// fan-out actually did.
    private static func requeuedCount(setupID: String, on db: any Database) async throws -> Int {
        try await APISubmission.query(on: db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$status == "pending")
            .count()
    }
}
