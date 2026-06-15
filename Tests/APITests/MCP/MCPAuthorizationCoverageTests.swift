// Architectural guard for per-resource authorization coverage.
//
// Every MCP tool that acts on a course/assignment/section must authorize the
// acting subject for that resource (`authorizeCourseAccess` /
// `authorizedAssignment*`), or at minimum confirm an MCP-eligible subject
// (`requireEligibleSubject`) before scoping its results to enrolled courses.
// This test scans each ContentTool source and fails the build if a tool omits
// the check — closing the regression risk that a newly-added tool forgets to
// authorize. (Runtime enumeration of the catalog is impractical here because
// each tool decodes different required arguments before its authz check runs,
// so a source-level guard is the robust form.)

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPAuthorizationCoverageTests {
    private static var toolsDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("Sources/APIServer/MCP/Tools")
    }

    /// Any of these in a tool's source satisfies the per-resource check.
    private static let authorizationCalls = [
        "authorizeCourseAccess",
        "authorizedAssignment",  // also matches authorizedAssignmentAndSetup
        "requireEligibleSubject",
    ]

    /// Tools that legitimately need no per-resource authorization: they touch no
    /// course/assignment/student/DB state and are gated only by the bearer scope.
    private static let unscopedToolFiles: Set<String> = [
        "GetServerInfoTool.swift"  // static version/capability probe
    ]

    @Test func everyToolFileAuthorizesItsResource() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.toolsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)  // sanity: the directory resolved

        var sawAToolFile = false
        for file in files where !Self.unscopedToolFiles.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Only files that declare a ContentTool conformance are in scope.
            guard source.contains(": ContentTool") else { continue }
            sawAToolFile = true
            let authorizes = Self.authorizationCalls.contains { source.contains($0) }
            #expect(
                authorizes,
                """
                MCP tool \(file.lastPathComponent) declares a ContentTool but calls no \
                authorization helper (authorizeCourseAccess / authorizedAssignment* / \
                requireEligibleSubject). Every resource-scoped tool must authorize the subject.
                """)
        }
        #expect(sawAToolFile)  // the ": ContentTool" detection actually matched
    }
}
