// Architectural guard for the close-on-edit + auto-retest chokepoint (#1115).
//
// Every MCP `content:write` tool must be classified: either its edit changes
// what the suite grades — and it must funnel through `finalizeContentEdit`
// (close a currently-open assignment, manifest-gated regrade, re-kick
// validation) — or it is explicitly listed as non-closing (metadata /
// structure / inputs edits that deliberately mirror the web's non-closing
// paths). `update_solution` is the one named exemption: it enqueues its own
// validation carrying the new solution and closes via
// `closeOpenAssignmentForContentEdit` directly.
//
// Same source-scan shape as MCPAuthorizationCoverageTests: a newly added
// write tool that calls neither helper and appears in no list fails the
// build with instructions, so "can a new write tool forget the close?" is a
// build failure instead of a silent gap — and the classification itself is
// written down exactly once, here.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPContentEditCoverageTests {
    private static var toolsDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("Sources/APIServer/MCP/Tools")
    }

    /// Write tools whose edits change what the suite grades: they MUST call
    /// `finalizeContentEdit` (close + manifest-gated retest + revalidate).
    private static let contentEditToolFiles: Set<String> = [
        "AuthorNotebookCheckTool.swift",
        "AuthorScriptTool.swift",
        "CreatePatternFamilyTool.swift",
        "DeleteSuiteItemTool.swift",
        // Removing a support file can break a test that sources it, so the
        // suite's behaviour changes even though no graded row is touched.
        "DeleteSupportFileTool.swift",
        "MoveSuiteItemTool.swift",  // placement-only: finalize with retest: false
        // Puts back a recorded version of the manifest + setup files: the graded
        // suite changes wholesale, so it closes and re-grades like any other edit.
        "RestoreAssignmentVersionTool.swift",
        "UpdateNotebookTool.swift",
        "UpdatePatternFamilyTool.swift",
        "UpdateSuiteTool.swift",
    ]

    /// The named exemption (#1115): closes via `closeOpenAssignmentForContentEdit`
    /// and enqueues its own validation (finalize's re-kick would validate the
    /// OLD solution); a solution-only edit never changes the manifest, so the
    /// manifest-gated retest would be a no-op.
    private static let handRolledCloseToolFiles: Set<String> = [
        "UpdateSolutionTool.swift"
    ]

    /// Write tools that deliberately do NOT close or regrade, mirroring the
    /// web paths they correspond to. Adding a file here is a policy decision —
    /// say why:
    private static let nonClosingWriteToolFiles: Set<String> = [
        // Creates a new, closed, unvalidated assignment; nothing to close.
        "CreateAssignmentTool.swift",
        // Clone lands closed/unvalidated with no submissions.
        "CloneAssignmentTool.swift",
        // Metadata only (title/due date/visibility); opening is refused until
        // validation passes, which is the actual gate.
        "UpdateAssignmentTool.swift",
        // Grading-mode flip; no regrade/close by design (documented in the
        // server instructions).
        "SetGradingModeTool.swift",
        // How students hand work in (editor vs upload); the suite grades the
        // same files either way, so nothing to close or regrade.
        "SetSubmissionModeTool.swift",
        // Declares the language generated tests will render in. Refused once
        // any generated test exists, so it cannot change what an existing suite
        // grades — the case that would warrant a close cannot arise.
        "SetAssignmentLanguageTool.swift",
        // Time limits are enforced at run time; no content change.
        "SetTimeLimitTool.swift",
        // Minimum-runner-version gate: changes which runner may grade, not what
        // the suite grades; enforced server-side at claim time. No close/regrade.
        "SetMinimumRunnerVersionTool.swift",
        // Dataset marks change delivery (per-student slices), not the graded
        // suite; mirrors the web PUT /datasets endpoint, which neither closes
        // nor regrades. Slices apply on the next (re)grade.
        "SetDatasetTool.swift",
        // Display-only awards; never change what the suite grades.
        "UpdateAchievementsTool.swift",
        // Shared inputs re-inline into scripts in place, matching the web
        // Global Inputs panel which neither closes nor regrades (#1115's
        // classification decision; see MCPServerInstructions).
        "UpdateGlobalInputsTool.swift",
        "UpdateSectionVariablesTool.swift",
        // Test-suite section CRUD: grouping/naming only, the dependency graph
        // and graded set are unchanged.
        "SuiteSectionTools.swift",
        // Course-section organization + assignment ordering: dashboard
        // structure, not content.
        "CourseSectionTools.swift",
        "AssignmentOrderingTools.swift",
        // Ungraded course content items (reference material). They own no test
        // setup, so create/update/delete/reorder never changes what any
        // assignment's suite grades — nothing to close or regrade.
        "CourseContentItemTools.swift",
    ]

    @Test func everyWriteToolIsClassifiedForCloseOnEdit() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.toolsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        var sawAWriteTool = false
        for file in files {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(": ContentTool") else { continue }
            // A file counts as a write-tool file when any tool in it requires
            // the write scope (matched on the requiredScopes declaration, not
            // a bare ".write", which read tools may mention in other code).
            let declaresWriteScope =
                source
                .components(separatedBy: "requiredScopes")
                .dropFirst()
                .contains { $0.prefix(80).contains(".write") }
            guard declaresWriteScope else { continue }
            sawAWriteTool = true

            let callsFinalize = source.contains("finalizeContentEdit(")
            let callsSharedClose = source.contains("closeOpenAssignmentForContentEdit(")

            if Self.contentEditToolFiles.contains(name) {
                #expect(
                    callsFinalize,
                    "\(name) is classified as a content edit but does not call finalizeContentEdit — its edits would leave an open assignment gradeable against a stale suite."
                )
            } else if Self.handRolledCloseToolFiles.contains(name) {
                #expect(
                    callsSharedClose,
                    "\(name) is the named finalize exemption and must close via closeOpenAssignmentForContentEdit (not a hand-rolled copy of the rule)."
                )
            } else {
                #expect(
                    Self.nonClosingWriteToolFiles.contains(name),
                    """
                    \(name) is a content:write tool that is not classified for the \
                    close-on-edit contract (#1115). Decide: if its edit changes what the \
                    suite grades, call finalizeContentEdit and add it to \
                    contentEditToolFiles; otherwise add it to nonClosingWriteToolFiles \
                    with a one-line justification.
                    """)
                #expect(
                    !callsFinalize,
                    "\(name) calls finalizeContentEdit but is classified non-closing — move it to contentEditToolFiles."
                )
            }
        }
        #expect(sawAWriteTool)
    }
}
