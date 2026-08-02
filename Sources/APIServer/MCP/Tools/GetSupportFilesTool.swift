// APIServer/MCP/Tools/GetSupportFilesTool.swift
//
// Read tool: list an assignment's support files (the non-graded helper/data
// files bundled in the test-setup zip), or read one of them, by assignment
// public ID. content:read, course-scoped.
//
// "Support file" uses the same classification as the shared-directory
// extraction (`extractSupportFilesToSharedDirectory`): a zip entry that is
// neither a graded suite script (read those via get_suite) nor one of the
// canonical notebooks (get_notebook / get_solution). This is the data a test
// or personalization expression can load at grading time — e.g. the CSV a
// pandas notebook check reads — which previously had no read surface at all:
// an agent could *write* one via author_script(tier:"support") but never
// confirm what was bundled, or author data-aware checks against its contents.
//
// Everything here is instructor-authored content from the setup zip — the same
// trust tier as get_suite/get_solution; no student data is reachable. Reads
// are byte-capped (maxBytes) so a large dataset returns a useful head instead
// of blowing the response budget.

import Core
import Fluent
import Foundation

struct GetSupportFilesTool: ContentTool {
    struct Input: Decodable, Sendable {
        let assignmentPublicID: String
        /// When present, read this support file; when omitted, list them all.
        let filename: String?
        /// Read mode: maximum content bytes returned (default 65536, clamped
        /// 1...512000). Truncation lands on a UTF-8 character boundary.
        let maxBytes: Int?
    }

    struct FileEntry: Encodable, Sendable {
        let filename: String
        let sizeBytes: Int
        /// Present when the file is marked as a per-student dataset
        /// (see set_dataset): rows each student receives, nil = whole file.
        let datasetSampleSize: Int?
        /// True when the file is a per-student dataset (docs/datasets.md).
        let isDataset: Bool
    }

    struct Output: Encodable, Sendable {
        let assignmentPublicID: String
        /// List mode: every support file in the setup zip (empty when none).
        /// Nil in read mode.
        let files: [FileEntry]?
        /// Read mode: the requested file. Nil in list mode.
        let filename: String?
        let sizeBytes: Int?
        /// UTF-8 content, possibly truncated to maxBytes (see `truncated`).
        let content: String?
        let truncated: Bool?
    }

    static let name = "get_support_files"
    static let description =
        "List an assignment's support files, or read one, by assignment public ID. Support files are "
        + "the non-graded helper/data files bundled in the test-setup zip (e.g. a CSV a notebook check "
        + "loads, or a helper module tests import) — everything in the zip that is not a graded suite "
        + "script (read those via get_suite) or the starter/solution notebook (get_notebook / "
        + "get_solution). Omit filename to list filenames and sizes; pass filename to read that file's "
        + "UTF-8 content, capped at maxBytes (default 65536) with truncated:true when the file is "
        + "larger — so a big dataset returns a useful head. Listed entries report per-student "
        + "dataset marks (isDataset / datasetSampleSize — set them with set_dataset). Write "
        + "support files with "
        + "author_script(tier:\"support\"). Read-only, instructor-authored content only; use it to "
        + "confirm a data file is actually bundled (and what its columns/rows look like) before "
        + "authoring checks that depend on it."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.assignmentPublicID,
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "A support filename from the list (exact match, subdirectory paths included). "
                        + "Omit to list all support files."),
            ]),
            "maxBytes": .object([
                "type": .string("integer"),
                "description": .string(
                    "Read mode: max content bytes returned (default 65536, clamped 1-512000)."),
            ]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "assignmentPublicID": MCPSchema.string,
            "files": .object(["type": .array([.string("array"), .string("null")])]),
            "filename": .object(["type": .array([.string("string"), .string("null")])]),
            "sizeBytes": .object(["type": .array([.string("integer"), .string("null")])]),
            "content": .object(["type": .array([.string("string"), .string("null")])]),
            "truncated": .object(["type": .array([.string("boolean"), .string("null")])]),
        ]),
        "required": .array([.string("assignmentPublicID")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.read]

    static let defaultMaxBytes = 65536
    static let maxMaxBytes = 512_000

    /// Zip entries that are never support files: the canonical notebooks have
    /// dedicated read tools. Matches `extractSupportFilesToSharedDirectory`.
    /// `DeleteSupportFileTool` reuses this so its remaining-count agrees with
    /// what this tool lists, instead of the two filters drifting apart.
    static let reservedNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let (assignment, setup) = try await context.authorizedAssignmentAndSetup(
            publicID: input.assignmentPublicID, tool: Self.name)

        let suiteScripts = Set(setup.decodedManifest()?.testSuites.map(\.script) ?? [])
        let supportNames = listZipEntries(zipPath: setup.zipPath).filter {
            !suiteScripts.contains($0) && !Self.reservedNames.contains($0)
        }

        guard let filename = input.filename else {
            let datasetSpecs = Dictionary(
                (setup.decodedManifest()?.datasets ?? []).map { ($0.file, $0) },
                uniquingKeysWith: { first, _ in first })
            let entries = supportNames.sorted().map { name in
                FileEntry(
                    filename: name,
                    sizeBytes: extractZipEntry(zipPath: setup.zipPath, entryName: name)?.count ?? 0,
                    datasetSampleSize: datasetSpecs[name]?.sampleSize,
                    isDataset: datasetSpecs[name] != nil)
            }
            return Output(
                assignmentPublicID: assignment.publicID,
                files: entries, filename: nil, sizeBytes: nil, content: nil, truncated: nil)
        }

        // Read mode. The filename must exactly match a support entry — a
        // graded script or notebook gets redirected to its dedicated tool, and
        // anything else (including a traversal attempt) is simply not in the
        // entry list.
        guard supportNames.contains(filename) else {
            if suiteScripts.contains(filename) {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "\"\(filename)\" is a graded suite script — read it via get_suite.")
            }
            if Self.reservedNames.contains(filename) {
                throw MCPToolError.invalidArguments(
                    tool: Self.name,
                    detail: "\"\(filename)\" is a notebook — read it via get_notebook or get_solution.")
            }
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "No support file named \"\(filename)\" in this assignment's setup "
                    + "(call without filename to list them).")
        }
        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: filename) else {
            throw MCPToolError.executionFailed(
                tool: Self.name, detail: "Failed to extract \"\(filename)\" from the setup zip.")
        }

        let cap = min(max(input.maxBytes ?? Self.defaultMaxBytes, 1), Self.maxMaxBytes)
        let (content, truncated) = try Self.utf8Content(of: data, cappedAt: cap, filename: filename)
        return Output(
            assignmentPublicID: assignment.publicID,
            files: nil, filename: filename, sizeBytes: data.count,
            content: content, truncated: truncated)
    }

    /// Decodes up to `cap` bytes of `data` as UTF-8, backing off to a character
    /// boundary when the cap splits a multi-byte sequence. Throws when the file
    /// is not UTF-8 text at all (this tool has no binary transport).
    private static func utf8Content(
        of data: Data, cappedAt cap: Int, filename: String
    ) throws -> (content: String, truncated: Bool) {
        if data.count <= cap {
            guard let text = String(data: data, encoding: .utf8) else {
                throw MCPToolError.invalidArguments(
                    tool: name,
                    detail: "\"\(filename)\" is not UTF-8 text; only text support files can be read.")
            }
            return (text, false)
        }
        var head = data.prefix(cap)
        // A UTF-8 character is at most 4 bytes, so at most 3 trailing bytes of
        // a split sequence need dropping before the prefix decodes.
        for _ in 0..<4 {
            if let text = String(data: head, encoding: .utf8) {
                return (text, true)
            }
            head = head.dropLast()
        }
        throw MCPToolError.invalidArguments(
            tool: name,
            detail: "\"\(filename)\" is not UTF-8 text; only text support files can be read.")
    }
}
