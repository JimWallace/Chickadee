// APIServer/Routes/Web/PublishedAssignmentRoutes+NotebookTools.swift
//
// Notebook-related editor tooling endpoints:
//   GET  /instructor/script-templates
//   POST /instructor/scan-notebook
//   POST /instructor/:assignmentID/create-solution
//
// Split out of `AssignmentRoutes+Editor.swift` in v0.4.183 (Phase 4.2
// of the audit-driven refactor).  No behaviour change.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {
    // MARK: - GET /instructor/script-templates
    //
    // Returns a JSON dict of generic (non-function-specific) script templates
    // keyed by the same identifiers used in the template <select> dropdown.

    @Sendable
    func getScriptTemplates(req: Request) async throws -> Response {
        var templates: [String: String] = [:]
        for type in PythonTestTemplateType.allCases {
            templates["py:\(type.rawValue)"] = pythonTestScript(type: type)
        }
        for type in ShellTestTemplateType.allCases {
            templates["sh:\(type.rawValue)"] = shellTestScript(type: type)
        }
        return try await templates.encodeResponse(for: req)
    }

    // MARK: - POST /instructor/scan-notebook
    //
    // Scans a solution notebook for Python function definitions and returns
    // one entry per public top-level function, along with pre-generated
    // script templates.
    //
    // Body: raw .ipynb JSON bytes (Content-Type: application/json or application/octet-stream)

    @Sendable
    func scanNotebook(req: Request) async throws -> Response {
        guard let buffer = req.body.data else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Request body is empty")
        }
        let notebookData = Data(buffer.readableBytesView)
        guard !notebookData.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Notebook data is empty")
        }

        // v0.4.111: switched from `scanNotebookForFunctions` to the
        // section-aware variant so each function carries the `## `
        // header it was defined under.  The family editor uses
        // `sectionName` to filter the dropdown to functions belonging
        // to the family's section — works on brand-new sections that
        // don't yet have any tests, which the filename-token filter
        // (v0.4.108–110) couldn't.
        // WHICH LANGUAGE. The client sends `?language=` (the editor now knows
        // it, from `#assignment-language-seed`); a request without it falls
        // back to the notebook's own kernelspec, which is a far better default
        // than assuming Python — assuming Python is what made this endpoint
        // answer "no functions found" for every R solution ever scanned.
        let requestedLanguage = req.query[String.self, at: "language"]
            .flatMap(AssignmentLanguage.init(rawValue:))
        let notebookLanguage: AssignmentLanguage? = {
            guard
                let object = (try? JSONSerialization.jsonObject(with: notebookData))
                    as? [String: Any],
                let metadata = object["metadata"] as? [String: Any]
            else { return nil }
            return AssignmentLanguage.fromNotebookMetadata(metadata)
        }()
        let scan = scanNotebookForSectionsAndFunctions(
            notebookData, language: requestedLanguage ?? notebookLanguage)

        // Forward ALL fields the scanner produces — not just a hand-picked
        // subset.  Pre-v0.4.94 this DTO dropped `paramTypes`, `returnType`,
        // `isShadowed`, and `paramHasDefault`, so the family-editor client
        // always saw them as undefined, which made `coerceByType` fall
        // back to untyped JSON.parse — a bare `20260422` in a `str` column
        // became `int(20260422)` and the renderer emitted a generated
        // test that then failed validation.
        struct FunctionResult: Content {
            var name: String
            var paramNames: [String]
            var paramCount: Int
            var paramTypes: [String?]
            var paramHasDefault: [Bool]
            var returnType: String?
            var hasTypeHints: Bool
            var hasDocstring: Bool
            var isShadowed: Bool
            /// The `##` markdown header the function was defined under
            /// in the solution notebook.  `nil` when the function
            /// appears before any `##` header.  v0.4.111+.
            var sectionName: String?
            var templates: [TestTemplateInfo]
        }

        let results = scan.functions.map { entry in
            let fn = entry.info
            return FunctionResult(
                name: fn.name,
                paramNames: fn.paramNames,
                paramCount: fn.paramCount,
                paramTypes: fn.paramTypes,
                paramHasDefault: fn.paramHasDefault,
                returnType: fn.returnType,
                hasTypeHints: fn.hasTypeHints,
                hasDocstring: fn.hasDocstring,
                isShadowed: fn.isShadowed,
                sectionName: entry.sectionName,
                templates: allTemplateInfos(functionName: fn.name, paramNames: fn.paramNames)
            )
        }

        // An OBJECT, not the bare array this used to return. The array could
        // only say "no functions", which is the same answer for an empty
        // solution and for a language the scanner cannot read — and an R author
        // got the first message for the second reason. `unsupportedReason`
        // carries the difference so the editor can show it.
        struct ScanResponse: Content {
            var functions: [FunctionResult]
            var unsupportedReason: String?
        }
        return try await ScanResponse(
            functions: results, unsupportedReason: scan.unsupportedReason
        ).encodeResponse(for: req)
    }

    // MARK: - POST /instructor/:assignmentID/create-solution

    @Sendable
    func createSolutionFromAssignment(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw WebAssignmentError.internalFailure(reason: "Authenticated user has no ID")
        }

        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)

        let sourceData =
            (try? notebookData(for: setup))
            ?? defaultNotebookData(title: "\(assignment.title) Solution")
        let normalized = normalizeNotebookForJupyterLite(sourceData)

        let draftPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        try normalized.write(to: URL(fileURLWithPath: draftPath))

        _ = try await ensureUserNotebookWorkingCopy(
            req: req, setupID: assignment.testSetupID, userID: userID, fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: assignment.testSetupID, userID: userID, fileKind: .solution),
            overwriteWith: normalized)

        return req.redirect(
            to: "/testsetups/\(assignment.testSetupID)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))")
    }
}
