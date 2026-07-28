// APIServer/MCP/Tools/AssignmentVersionTools.swift
//
// Read tools over an assignment's content-version history
// (docs/assignment-versioning.md):
//
//   list_assignment_versions — the timeline: who changed what, when
//   get_assignment_version   — one past version's manifest, file list, and
//                              optionally one file's body
//
// `get_assignment_version` reads a past version WITHOUT touching the live
// assignment, which is the point: an agent asked to explain or undo a bad edit
// can read what the script used to say, decide, and only then restore. Restore
// itself is a separate write tool.
//
// Both read `assignment_versions` on the OWNER pool (`ToolContext.mainDB`), not
// the least-privilege `.mcp` pool. The table is deliberately ungranted to the
// `chickadee_mcp` role (deploy/sql/mcp-least-privilege-role.sql grants nothing
// by default), so a query through `context.db` would fail with permission
// denied wherever the dedicated pool is configured — the same routing the
// capture path uses on the way in.
//
// Snapshots hold secret-tier tests and reference solutions. Authorization is
// therefore identical to `get_suite`'s (`authorizedAssignmentAndSetup`, which
// requires an MCP-eligible subject enrolled in the assignment's course, and
// students can never be MCP-eligible), so the file-body path is not a way
// around the content wall it already sits behind.

import Core
import Fluent
import Foundation

// MARK: - list_assignment_versions

struct ListAssignmentVersionsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// Max entries returned (default 50, clamped 1...200).
        let limit: Int?
        /// Return only versions numbered strictly below this, for paging back
        /// through a long history.
        let beforeVersion: Int?
    }

    struct Entry: Encodable, Sendable {
        let version: Int
        let createdAt: String
        /// Username of whoever caused the edit; nil for system-originated
        /// snapshots (baseline, import).
        let actor: String?
        /// What produced it: `baseline`, `clone`, `mcp:<tool>`, `web:<route>`,
        /// `restore:<n>`.
        let origin: String
        let summary: String?
        let manifestHash: String
        let fileCount: Int
        let hasNotebook: Bool
        /// Set when this version was produced by restoring an earlier one.
        let restoredFromVersion: Int?
        /// True for the version matching the assignment's current content.
        let isCurrent: Bool
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let currentVersion: Int?
        let totalVersions: Int
        let versions: [Entry]
    }

    static let name = "list_assignment_versions"
    static let description =
        "List an assignment's content-version history, newest first. Every content edit — made here "
        + "or in the browser — records an immutable snapshot of the manifest, test-setup files, and "
        + "starter notebook, and snapshots are never deleted. Each entry reports who made the edit, "
        + "when, and what produced it (origin: `baseline` for the state before the first recorded "
        + "edit, `mcp:<tool>`, `web:<route>`, `clone`, or `restore:<n>`). Use it to answer \"what "
        + "changed and when did this break\", then read a specific version with "
        + "get_assignment_version and put one back with restore_assignment_version. Read-only; "
        + "returns no student data."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Max entries returned (default 50, clamped 1-200)."),
            ]),
            "beforeVersion": .object([
                "type": .string("integer"),
                "description": .string(
                    "Return only versions numbered below this, to page back through a long history."
                ),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "currentVersion": .object(["type": .array([.string("integer"), .string("null")])]),
            "totalVersions": MCPSchema.integer,
            "versions": .object(["type": .string("array")]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("totalVersions"), .string("versions"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.read]

    static let defaultLimit = 50
    static let maxLimit = 200

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (_, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)
        let setupID = setup.id ?? ""
        let limit = min(max(input.limit ?? Self.defaultLimit, 1), Self.maxLimit)

        var query = APIAssignmentVersion.query(on: context.mainDB)
            .filter(\.$testSetupID == setupID)
        if let before = input.beforeVersion {
            query = query.filter(\.$versionNumber < before)
        }
        let rows =
            try await query
            .sort(\.$versionNumber, .descending)
            .limit(limit)
            .all()

        let total = try await APIAssignmentVersion.query(on: context.mainDB)
            .filter(\.$testSetupID == setupID)
            .count()

        // "Current" is whichever version matches the live content, which is
        // the newest one unless the setup was edited outside a capture point.
        // Comparing hashes rather than assuming max() keeps the report honest
        // if that ever happens.
        let liveManifestHash = manifestHash(setup.manifest)
        let newest = rows.map(\.versionNumber).max()

        let formatter = ISO8601DateFormatter()
        let entries = rows.map { row in
            Entry(
                version: row.versionNumber,
                createdAt: row.createdAt.map(formatter.string(from:)) ?? "",
                actor: row.actorUsername,
                origin: row.origin,
                summary: row.summary,
                manifestHash: row.manifestHash,
                fileCount: row.decodedFileMap().count,
                hasNotebook: row.notebookHash != nil,
                restoredFromVersion: row.restoredFromVersion,
                isCurrent: row.versionNumber == newest && row.manifestHash == liveManifestHash)
        }

        return Output(
            assignmentPublicID: input.assignmentPublicID,
            currentVersion: entries.first(where: \.isCurrent)?.version,
            totalVersions: total,
            versions: entries)
    }
}

// MARK: - get_assignment_version

struct GetAssignmentVersionTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        let version: Int
        /// When present, also return this file's body from the snapshot.
        let path: String?
        /// Read mode: max content bytes returned (default 65536, clamped
        /// 1...512000).
        let maxBytes: Int?
    }

    struct FileEntry: Encodable, Sendable {
        let path: String
        let sizeBytes: Int
        /// True when this file's bytes differ from the live assignment's.
        let differsFromCurrent: Bool
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        let version: Int
        let createdAt: String
        let actor: String?
        let origin: String
        let summary: String?
        /// The full manifest JSON as it stood at this version.
        let manifest: String
        let files: [FileEntry]
        let hasNotebook: Bool
        /// Read mode: the requested file. Nil when `path` was omitted.
        let path: String?
        let content: String?
        let truncated: Bool?
    }

    static let name = "get_assignment_version"
    static let description =
        "Read one past version of an assignment's content by version number, WITHOUT changing the "
        + "live assignment. Returns that version's full manifest, its file list (each marked "
        + "differsFromCurrent so a changed script is obvious at a glance), and — when `path` is "
        + "given — that file's body as it was then, capped at maxBytes. Use it to see what a test "
        + "or support file used to contain before deciding whether to put it back with "
        + "restore_assignment_version. Get version numbers from list_assignment_versions. "
        + "Read-only; returns no student data."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "version": .object([
                "type": .string("integer"),
                "description": .string("Version number, from list_assignment_versions."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "A path from this version's file list (exact match). Omit to return metadata "
                        + "and the file list only."),
            ]),
            "maxBytes": .object([
                "type": .string("integer"),
                "description": .string(
                    "Read mode: max content bytes returned (default 65536, clamped 1-512000)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID"), .string("version")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "version": MCPSchema.integer,
            "createdAt": MCPSchema.string,
            "actor": .object(["type": .array([.string("string"), .string("null")])]),
            "origin": MCPSchema.string,
            "summary": .object(["type": .array([.string("string"), .string("null")])]),
            "manifest": MCPSchema.string,
            "files": .object(["type": .string("array")]),
            "hasNotebook": MCPSchema.boolean,
            "path": .object(["type": .array([.string("string"), .string("null")])]),
            "content": .object(["type": .array([.string("string"), .string("null")])]),
            "truncated": .object(["type": .array([.string("boolean"), .string("null")])]),
        ]),
        "required": .array([
            .string("assignmentPublicID"), .string("version"), .string("origin"),
            .string("manifest"), .string("files"),
        ]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.read]

    static let defaultMaxBytes = 65536
    static let maxMaxBytes = 512_000

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (_, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)
        let row = try await Self.requireVersion(
            setupID: setup.id ?? "", number: input.version, on: context.mainDB)

        let blobs = AssignmentVersionBlobStore(
            testSetupsDirectory: context.request.application.testSetupsDirectory)
        let fileMap = row.decodedFileMap()
        let live = try await Self.liveFileHashes(setup: setup)

        let files = fileMap.keys.sorted().map { path in
            FileEntry(
                path: path,
                sizeBytes: Self.blobSize(fileMap[path] ?? "", blobs: blobs),
                differsFromCurrent: live[path] != fileMap[path])
        }

        var body: (content: String, truncated: Bool)?
        if let path = input.path {
            body = try Self.readFile(path: path, fileMap: fileMap, blobs: blobs, input: input)
        }

        return Output(
            assignmentPublicID: input.assignmentPublicID,
            version: row.versionNumber,
            createdAt: row.createdAt.map(ISO8601DateFormatter().string(from:)) ?? "",
            actor: row.actorUsername,
            origin: row.origin,
            summary: row.summary,
            manifest: row.manifest,
            files: files,
            hasNotebook: row.notebookHash != nil,
            path: input.path,
            content: body?.content,
            truncated: body?.truncated)
    }

    /// Loads a version, mapping "no such version" to an actionable error rather
    /// than an empty result the agent has to interpret.
    static func requireVersion(
        setupID: String, number: Int, tool: String = name, on db: any Database
    ) async throws -> APIAssignmentVersion {
        guard
            let row = try await APIAssignmentVersion.query(on: db)
                .filter(\.$testSetupID == setupID)
                .filter(\.$versionNumber == number)
                .first()
        else {
            let newest = try await AssignmentVersionStore.newestVersion(setupID: setupID, on: db)
            let available =
                newest.map { "Versions 1-\($0.versionNumber) exist." }
                ?? "This assignment has no recorded versions yet."
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "No version \(number) for this assignment. \(available)")
        }
        return row
    }

    /// Hash every entry in the assignment's CURRENT zip, so the file list can
    /// mark what actually differs. Reuses the snapshot builder rather than
    /// re-implementing the walk, so "differs" means exactly what the dedupe
    /// means and the two can't drift.
    private static func liveFileHashes(setup: APITestSetup) async throws -> [String: String] {
        // A throwaway store: hashing is the goal, and writing the blobs is
        // harmless (they are content-addressed, so at worst this pre-populates
        // bytes a later snapshot would have written anyway).
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-version-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let scratch = AssignmentVersionBlobStore(testSetupsDirectory: temp.path)
        let snapshot = try await AssignmentVersionSnapshotBuilder.build(
            setup: setup, blobs: scratch)
        return snapshot.fileMap
    }

    private static func blobSize(_ hash: String, blobs: AssignmentVersionBlobStore) -> Int {
        guard let path = try? blobs.path(for: hash),
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int
        else { return 0 }
        return size
    }

    private static func readFile(
        path: String, fileMap: [String: String], blobs: AssignmentVersionBlobStore, input: Input
    ) throws -> (content: String, truncated: Bool) {
        guard let hash = fileMap[path] else {
            throw MCPToolError.invalidArguments(
                tool: name,
                detail:
                    "No file \"\(path)\" in version \(input.version). Its files: "
                    + fileMap.keys.sorted().joined(separator: ", "))
        }
        let data: Data
        do {
            data = try blobs.read(hash)
        } catch {
            // A blob that a version row references but that isn't on disk means
            // the store lost bytes — report it as such rather than as an empty
            // file, which would read as "this script used to be blank".
            throw MCPToolError.executionFailed(
                tool: name,
                detail: "Stored content for \"\(path)\" is missing from the version blob store.")
        }
        let cap = min(max(input.maxBytes ?? defaultMaxBytes, 1), maxMaxBytes)
        guard let text = truncatedUTF8(data, maxBytes: cap) else {
            throw MCPToolError.invalidArguments(
                tool: name,
                detail:
                    "\"\(path)\" is not UTF-8 text (\(data.count) bytes) — it can be restored, but "
                    + "not read here.")
        }
        return text
    }

    /// Decodes `data` as UTF-8, truncated to `maxBytes` on a character
    /// boundary. Returns nil for content that isn't valid UTF-8 at all (a
    /// bundled image or archive), so the caller can say so rather than hand an
    /// agent mojibake it might mistake for the file's real contents.
    private static func truncatedUTF8(
        _ data: Data, maxBytes: Int
    ) -> (content: String, truncated: Bool)? {
        guard data.count > maxBytes else {
            return String(bytes: data, encoding: .utf8).map { ($0, false) }
        }
        var slice = data.prefix(maxBytes)
        // Back off to a character boundary so the tail isn't a broken scalar.
        // Bounded by `maxBytes`: a non-UTF-8 file drains the slice and reports
        // nil rather than looping.
        while !slice.isEmpty, String(bytes: slice, encoding: .utf8) == nil {
            slice = slice.dropLast()
        }
        guard let content = String(bytes: slice, encoding: .utf8), !slice.isEmpty else {
            return nil
        }
        return (content, true)
    }
}
