// APIServer/MCP/Tools/LectureNotebookTools.swift
//
// The MCP half of lecture notebooks (docs/lecture-notebooks.md): an ungraded
// content item whose notebook opens in the editor. `create_content_item` and
// `update_content_item` take a `lectureNotebook` argument (the shared input
// and schema below), and `get_lecture_notebook` reads the stored notebook so
// an agent can edit it and write it back. The writes go through
// `LectureNotebookService`, which the web form shares.
//
// No language is named here: the languages a lecture may declare are those
// with an editor kernel, and `get_server_info` reports which those are.

import Core
import Fluent
import Foundation
import Vapor

/// The `lectureNotebook` argument of `create_content_item` and
/// `update_content_item`.
struct LectureNotebookInput: Decodable, Sendable {
    /// The declared language token. Required on create; on update, changes
    /// the declaration.
    let language: String?
    /// The whole notebook as .ipynb JSON. Optional on create (a blank notebook
    /// in the language), and on update replaces the stored notebook.
    let notebook: JSONValue?

    init(language: String? = nil, notebook: JSONValue? = nil) {
        self.language = language
        self.notebook = notebook
    }

    /// The notebook bytes, checked for shape, or nil when none was given.
    func notebookData() throws -> Data? {
        guard let notebook else { return nil }
        try validateNotebookShape(notebook)
        do {
            return try JSONEncoder().encode(notebook)
        } catch {
            throw MCPToolError.invalidArguments(detail: "notebook could not be encoded as JSON.")
        }
    }
}

/// What a content item's output says about its lecture notebook.
struct LectureNotebookDTO: Encodable, Sendable {
    /// The declared language token, or nil when the setup cannot be read.
    let language: String?
    /// Where an enrolled student opens their own copy in the editor.
    let notebookPath: String
    /// Where course staff edit and save the notebook.
    let editPath: String
}

func lectureNotebookDTO(for item: APICourseContentItem, setup: APITestSetup?) -> LectureNotebookDTO? {
    guard let setupID = item.lectureTestSetupID else { return nil }
    return LectureNotebookDTO(
        language: setup.flatMap(LectureNotebookService.declaredLanguage(of:))?.rawValue,
        notebookPath: "/testsetups/\(setupID)/notebook",
        editPath: "/testsetups/\(setupID)/notebook?edit=1")
}

/// The `lectureNotebook` input schema.
let lectureNotebookInputSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "language": .object([
            "type": .string("string"),
            "description": .string(
                "The notebook's declared language token. It must be a language with an in-browser "
                    + "editor kernel (get_server_info reports which). There is no default."),
        ]),
        "notebook": .object([
            "type": .string("object"),
            "description": .string(
                "The full notebook as .ipynb JSON (an object with a \"cells\" array)."),
        ]),
    ]),
    "description": .string(
        "Makes the item a lecture notebook: ungraded, its notebook hosted here and opened in the "
            + "notebook editor, where each enrolled student gets a copy of their own. No submission, "
            + "no grade, no LMS push, no validation. On create, language is required and notebook is "
            + "optional (a blank notebook in the language). On update of a lecture notebook, language "
            + "changes the declaration and notebook replaces the stored notebook; a student's existing "
            + "copy is never rewritten, so they get the new version when they first open it or reset "
            + "their copy. An existing item of another kind cannot become a lecture notebook."),
])

/// The `lectureNotebook` output schema, for the content-item object.
let lectureNotebookOutputSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "language": MCPSchema.string,
        "notebookPath": MCPSchema.string,
        "editPath": MCPSchema.string,
    ]),
    "required": .array([.string("notebookPath"), .string("editPath")]),
])

// MARK: - get_lecture_notebook

struct GetLectureNotebookTool: ContentTool {
    struct Input: Decodable, Sendable {
        let contentItemID: String
    }

    struct Output: Encodable, Sendable {
        let contentItemID: String
        let language: String?
        let cellCount: Int
        let notebook: JSONValue
    }

    static let name = "get_lecture_notebook"
    static let description =
        "Get a lecture notebook's stored notebook as .ipynb JSON, by content-item id (from "
        + "list_content_items, where a lecture notebook carries a lectureNotebook object). Returns the "
        + "declared language, the notebook and a cell count. This is the version a student is seeded "
        + "with when they first open it; it never includes any student's copy. Read-only."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItemID": .object([
                "type": .string("string"),
                "description": .string("Content-item id (from list_content_items)."),
            ])
        ]),
        "required": .array([.string("contentItemID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItemID": MCPSchema.string,
            "language": MCPSchema.string,
            "cellCount": MCPSchema.integer,
            "notebook": .object(["type": .string("object")]),
        ]),
        "required": .array([.string("contentItemID"), .string("cellCount"), .string("notebook")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let raw = input.contentItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments(detail: "contentItemID \"\(raw)\" is not a valid id.")
        }
        guard let item = try await APICourseContentItem.find(uuid, on: context.db) else {
            throw MCPToolError.invalidArguments(detail: "No content item with id \"\(raw)\".")
        }
        try await context.authorizeCourseAccess(item.courseID)
        guard let setup = try await LectureNotebookService.setup(of: item, on: context.db) else {
            throw mcpToolError(.notALectureNotebook)
        }
        let data: Data
        do {
            data = try await context.request.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            throw MCPToolError.executionFailed(detail: "This lecture notebook has no stored notebook to return.")
        }
        let notebook: JSONValue
        do {
            notebook = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MCPToolError.executionFailed(detail: "The stored notebook is not valid JSON.")
        }
        return Output(
            contentItemID: raw,
            language: LectureNotebookService.declaredLanguage(of: setup)?.rawValue,
            cellCount: notebookCellCount(notebook),
            notebook: notebook)
    }
}
