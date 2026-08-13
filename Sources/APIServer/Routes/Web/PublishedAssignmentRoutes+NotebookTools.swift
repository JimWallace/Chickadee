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
        // The shell templates name a solution file and an interpreter, so they
        // need the assignment's language. The editor knows it (from
        // `#assignment-language-seed`) and passes it; an absent parameter keeps
        // Python, which is what this endpoint returned before it asked.
        let language = req.query[String.self, at: "language"]
            .flatMap(AssignmentLanguage.init(rawValue:))
        var templates: [String: String] = [:]
        for type in PythonTestTemplateType.allCases {
            templates["py:\(type.rawValue)"] = pythonTestScript(type: type)
        }
        for type in ShellTestTemplateType.allCases {
            templates["sh:\(type.rawValue)"] = shellTestScript(type: type, language: language)
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
        // WHICH LANGUAGE, in precedence order: the client's `?language=` (the
        // editor knows it now, from `#assignment-language-seed`), then the
        // notebook's own kernelspec, then Python.
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
        // FALL BACK TO PYTHON when neither says anything, which is this
        // endpoint's historical contract. Refusing on "unknown" would be a
        // regression with no upside: the languages this fix is for all declare
        // a kernelspec (`xr`, `ir`, `xlua`, `xoctave`) and are detected, and
        // classic Jupyter writes `python3`, so a notebook that declares nothing
        // recognisable is a hand-crafted one that used to scan fine. The
        // distinction being restored is between the languages we can read and
        // the ones we cannot — not between declared and undeclared.
        let scannedLanguage = requestedLanguage ?? notebookLanguage
        let scan = scanNotebookForSectionsAndFunctions(
            notebookData, language: scannedLanguage ?? .python)

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
                // The language, PASSED. Omitting it took `allTemplateInfos`'
                // default and handed every author — R, Lua, Octave, C++,
                // Racket — the Python shell templates, which is the exact
                // defect `shellTestScript` was taught to render per-language
                // for. The default is gone now, so this cannot silently
                // regress. Unlike the scan itself, an unrecognised notebook
                // does NOT become Python here: a template with no language is
                // a shell scaffold, which is a better answer than a confident
                // `python3` for a suite nobody has claimed.
                templates: allTemplateInfos(
                    functionName: fn.name, paramNames: fn.paramNames,
                    language: scannedLanguage)
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
            /// The `## ` headers found, whatever the language.
            ///
            /// Reported even when `unsupportedReason` is set: a section name is
            /// markdown, not code, so the reason the functions could not be
            /// read does not apply to it. The editor can offer sections to an
            /// R or Lua author while still saying why the function list is
            /// empty.
            var sectionNames: [String]
        }
        return try await ScanResponse(
            functions: results, unsupportedReason: scan.unsupportedReason,
            sectionNames: scan.sectionNames
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

        // The assignment notebook when there is one; otherwise a blank starter
        // IN THIS ASSIGNMENT'S LANGUAGE. The fallback used to be Python
        // unconditionally, so an R assignment with no notebook yet got a
        // solution scaffolded around `xpython`. An upload-only language has no
        // notebook to scaffold at all and is refused.
        let language = setup.decodedManifest().flatMap {
            AssignmentLanguage.resolve(for: setup, manifest: $0)
        }
        guard
            let sourceData = (try? notebookData(for: setup))
                ?? defaultNotebookData(title: "\(assignment.title) Solution", language: language)
        else {
            throw WebAssignmentError.unprocessable(reason: uploadOnlyNotebookScaffoldMessage)
        }
        let normalized = normalizeNotebookForJupyterLite(sourceData)

        let draftPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        _ = try ensureDraftNotebookDirectory(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        try await req.fileio.writeFile(.init(data: normalized), at: draftPath)

        _ = try await ensureUserNotebookWorkingCopy(
            req: req, setupID: assignment.testSetupID, userID: userID, fallbackSetup: setup,
            relativePath: userNotebookWorkingCopyRelativePath(
                setupID: assignment.testSetupID, userID: userID, fileKind: .solution),
            overwriteWith: normalized)

        return req.redirect(
            to: "/testsetups/\(assignment.testSetupID)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))")
    }
}
