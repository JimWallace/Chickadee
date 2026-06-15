// Architectural guard for the MCP student-data wall.
//
// The MCP tool surface may touch the submissions/results tables ONLY through
// `MCPStudentDataBoundary` (which hard-filters to validation runs), and must
// never name any other student-data model. These tests scan the tool source
// files and fail the build if a handler references a forbidden model — so the
// wall cannot regress when a new tool is added. Source scanning is the same
// technique the repo already uses for `no-new-xctest` and the audit-action
// coverage test.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPStudentDataWallTests {
    /// `Sources/APIServer/MCP/Tools`, resolved from this test file's location.
    private static var toolsDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("Sources/APIServer/MCP/Tools")
    }

    /// Student-data models the MCP tool surface must never reference directly.
    /// After the boundary refactor, `APISubmission` / `APIResult` appear only in
    /// `MCPStudentDataBoundary.swift`; every other model here is never named by
    /// the surface at all.
    private static let forbiddenModels = [
        "APISubmission", "APIResult", "APIGradeOverride", "APIClientDiagnostic",
        "APISubmissionDiagnostics", "JobExecutionMetric", "APIClassAchievement",
        "APIAchievementResult", "APIUserActivityEvent", "APIBrightSpaceSyncLog",
        "APIPreEnrollment", "APIAssignmentParticipation", "APIAssignmentExtension",
    ]

    private static let boundaryFile = "MCPStudentDataBoundary.swift"

    private func swiftFiles(in dir: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    @Test func toolSurfaceReferencesStudentModelsOnlyThroughTheBoundary() throws {
        let files = try swiftFiles(in: Self.toolsDirectory)
        #expect(!files.isEmpty)  // sanity: the directory resolved
        for file in files where file.lastPathComponent != Self.boundaryFile {
            let source = try String(contentsOf: file, encoding: .utf8)
            for model in Self.forbiddenModels {
                #expect(
                    !source.contains(model),
                    """
                    MCP tool \(file.lastPathComponent) references student-data model \(model). \
                    Route validation-run access through MCPStudentDataBoundary; never query \
                    student submissions, results, or roster/PII from a tool handler.
                    """)
            }
        }
    }

    @Test func boundaryIsTheChokepointAndStillFiltersToValidation() throws {
        let boundary = try String(
            contentsOf: Self.toolsDirectory.appendingPathComponent(Self.boundaryFile),
            encoding: .utf8)
        // The chokepoint actually owns the access...
        #expect(boundary.contains("APISubmission"))
        #expect(boundary.contains("APIResult"))
        // ...and keeps the validation filter that makes student rows unreachable.
        #expect(boundary.contains("kind == APISubmission.Kind.validation"))
    }

    // P1-3: the reference-solution notebook (the answer key) is read only via the
    // shared `loadExistingSolution` resolver. Guard that no NEW tool starts
    // emitting it — only get_solution reads it on the MCP surface (update_solution
    // writes, preview_personalization materializes through its own path).
    @Test func solutionNotebookResolverRestrictedToGetSolution() throws {
        let allowed = "GetSolutionTool.swift"
        for file in try swiftFiles(in: Self.toolsDirectory)
        where file.lastPathComponent != allowed {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Match the call site, not a doc-comment mention of the resolver.
            #expect(
                !source.contains("loadExistingSolution("),
                """
                MCP tool \(file.lastPathComponent) reads the reference solution via \
                loadExistingSolution; the answer key should leave the boundary only through \
                get_solution. Re-check payload minimization before allowing this.
                """)
        }
    }
}
