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

    /// The content surface's non-tool directories, in scope for the same wall:
    /// the transport/dispatch layer and the resource provider run with the
    /// same MCP database context as the tools (audit F-6). The Admin/ and
    /// OAuth/ trees are deliberately NOT scanned — the admin diagnostic tools
    /// legitimately read diagnostic tables behind their own allowlisted DTOs,
    /// and the OAuth layer resolves the human account by design.
    private static var additionalContentDirectories: [URL] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let mcp = url.appendingPathComponent("Sources/APIServer/MCP")
        return [
            mcp.appendingPathComponent("Transport"),
            mcp.appendingPathComponent("Resources"),
        ]
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

    /// The wall also covers the content surface's transport + resource layers
    /// (audit F-6): a dispatcher or resource handler must not name a
    /// student-data model any more than a tool may.
    @Test func transportAndResourceLayersReferenceNoStudentModels() throws {
        for dir in Self.additionalContentDirectories {
            for file in try swiftFiles(in: dir) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for model in Self.forbiddenModels {
                    #expect(
                        !source.contains(model),
                        """
                        MCP content-surface file \(file.lastPathComponent) references \
                        student-data model \(model). The transport/resource layers sit inside \
                        the student-data wall; route any legitimate need through a tool + \
                        MCPStudentDataBoundary instead.
                        """)
                }
            }
        }
    }

    /// Identity models (`APIUser`, `APICourseEnrollment`) are not in
    /// `forbiddenModels` because the authorization layer must query them — but
    /// ONLY the authorization layer. A tool that named them could list roster
    /// or enrollment data the DB role cannot block (users/course_enrollments
    /// are SELECT-granted for authz — audit F-6). Everything outside this
    /// allowlist must resolve identity through `ToolContext`.
    private static let identityModels = ["APIUser", "APICourseEnrollment"]
    private static let identityAllowlist: Set<String> = [
        "ToolContext.swift",  // requireEligibleSubject / authorizeCourseAccess
        "MCPCourseGuidance.swift",  // resolves the acting subject's own courses at initialize
    ]

    @Test func identityModelsConfinedToTheAuthorizationLayer() throws {
        let directories = [Self.toolsDirectory] + Self.additionalContentDirectories
        for dir in directories {
            for file in try swiftFiles(in: dir)
            where !Self.identityAllowlist.contains(file.lastPathComponent) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for model in Self.identityModels {
                    #expect(
                        !source.contains(model),
                        """
                        MCP content-surface file \(file.lastPathComponent) references identity \
                        model \(model). Roster/enrollment data must stay unreachable from the \
                        tool surface — resolve the acting subject through ToolContext \
                        (requireEligibleSubject / authorizeCourseAccess) instead of querying \
                        identity models directly.
                        """)
                }
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
