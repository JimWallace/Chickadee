// Architectural guard for content-version capture on the MCP write tools
// (docs/assignment-versioning.md).
//
// A `content:write` tool that changes an assignment's content must produce a
// version, or the history has a hole — and a hole is worse than no history,
// because a later restore would silently discard whatever the unrecorded edit
// did.
//
// Capture hangs off `ToolContext.authorizedAssignmentAndSetupForWrite`, so a
// tool that resolves its setup the normal way is versioned automatically. This
// test exists for the tools that DON'T: each must either register by hand
// (`beginContentWrite`) or be listed here as touching no assignment content,
// with a reason. Same source-scan shape as `MCPContentEditCoverageTests`, and
// the same intent — the classification is written down exactly once, and a new
// write tool that slips through is a build failure with instructions.

import Foundation
import Testing

@testable import APIServer

@Suite struct MCPVersionCaptureCoverageTests {
    private static var toolsDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/MCP/<thisFile>
        for _ in 0..<4 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("Sources/APIServer/MCP/Tools")
    }

    /// Write tools that own no assignment content, so there is nothing to
    /// snapshot. Adding a file here is a policy decision — say why:
    private static let noAssignmentContentToolFiles: Set<String> = [
        // Creates a brand-new assignment. Its first version is seeded by the
        // creation path itself, not by an edit capture.
        "CreateAssignmentTool.swift",
        "CloneAssignmentTool.swift",
        // Assignment metadata only (title / due date / visibility). None of it
        // is content: a restore deliberately does not put these back, so
        // versioning them would record state a restore can't act on.
        "UpdateAssignmentTool.swift",
        // Course-section organization and assignment ordering: dashboard
        // structure, stored on the course/assignment rows, not in any manifest.
        "CourseSectionTools.swift",
        "AssignmentOrderingTools.swift",
        // Ungraded course content items (reference material). They own no test
        // setup at all.
        "CourseContentItemTools.swift",
    ]

    /// Write tools that reach their setup without the standard seam and so
    /// register for capture by hand.
    private static let handRegisteredToolFiles: Set<String> = [
        // Resolves the assignment, then writes solution.ipynb into the setup
        // zip by id — it never loads the setup through the write seam.
        "UpdateSolutionTool.swift"
    ]

    @Test func everyWriteToolIsClassifiedForVersionCapture() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.toolsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        var sawAWriteTool = false
        for file in files {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(": ContentTool") else { continue }
            // Matched on the requiredScopes declaration rather than a bare
            // ".write", which a read tool may mention in other code.
            let declaresWriteScope =
                source
                .components(separatedBy: "requiredScopes")
                .dropFirst()
                .contains { $0.prefix(80).contains(".write") }
            guard declaresWriteScope else { continue }
            sawAWriteTool = true

            let usesWriteSeam = source.contains("authorizedAssignmentAndSetupForWrite(")
            let registersByHand = source.contains("beginContentWrite(")

            if Self.handRegisteredToolFiles.contains(name) {
                #expect(
                    registersByHand,
                    "\(name) is classified as hand-registering for version capture but never calls beginContentWrite — its content edits would go unrecorded."
                )
                continue
            }

            if usesWriteSeam || registersByHand { continue }

            #expect(
                Self.noAssignmentContentToolFiles.contains(name),
                """
                \(name) is a content:write tool that neither resolves its setup through \
                authorizedAssignmentAndSetupForWrite nor calls beginContentWrite, and is \
                not classified as owning no assignment content. Decide: if it changes \
                manifest / setup-zip / notebook content, route it through the write seam \
                (or call beginContentWrite before mutating); otherwise add it to \
                noAssignmentContentToolFiles with a one-line justification.
                """)
        }
        #expect(sawAWriteTool)
    }

    /// The seam only works if it actually seeds the baseline and registers the
    /// setup. Pinned directly, because every tool's coverage above is inferred
    /// from the mere presence of the call.
    @Test func theWriteSeamRegistersForCapture() throws {
        let contextSource = try String(
            contentsOf: Self.toolsDirectory.appendingPathComponent("ToolContext.swift"),
            encoding: .utf8)
        let seam = try #require(
            contextSource.components(separatedBy: "func authorizedAssignmentAndSetupForWrite").last)
        #expect(
            seam.prefix(900).contains("beginContentWrite("),
            "authorizedAssignmentAndSetupForWrite no longer registers for version capture — every write tool's history depends on it."
        )
    }

    /// Capture must run on the owner pool: `assignment_versions` is
    /// deliberately not granted to the least-privilege `chickadee_mcp` role,
    /// so writing it through `context.db` would fail with permission denied on
    /// any deployment that configures the dedicated pool.
    @Test func captureWritesOnTheOwnerPool() throws {
        let source = try String(
            contentsOf: Self.toolsDirectory.appendingPathComponent("MCPVersionCapture.swift"),
            encoding: .utf8)
        #expect(source.contains("on: mainDB"))
        #expect(!source.contains("on: db)"))
    }
}
