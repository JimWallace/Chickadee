// Tests/APITests/Guards/CourseRoleFloorGuardTests.swift
//
// `CourseRoleFloor` names the floor of each operation once, so a web route,
// its MCP twin and the view that offers its control cannot drift (#2772).
// This guard reads the files that implement a named operation. A literal
// floor (`atLeast:` followed by a bare role case) in one of them fails here,
// unless the file lists it as a deliberate one-off: a different operation
// that has no name.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct CourseRoleFloorGuardTests {

    /// The value of each floor. A change here is a policy change on every
    /// surface at once, so it must be deliberate.
    @Test func eachFloorHasItsDocumentedValue() {
        #expect(CourseRoleFloor.createAssignment == .instructor)
        #expect(CourseRoleFloor.assignmentLifecycle == .instructor)
        #expect(CourseRoleFloor.manageSections == .instructor)
        #expect(CourseRoleFloor.manageContentItems == .ta)
        #expect(CourseRoleFloor.manageCourseDatasets == .ta)
        #expect(CourseRoleFloor.studentOptions == .instructor)
        #expect(CourseRoleFloor.classActivity == .instructor)
        #expect(CourseRoleFloor.brightSpaceBinding == .instructor)
    }

    /// Each file that implements a named operation, with the number of literal
    /// floors it keeps on purpose. Each kept literal guards an operation that
    /// has no name:
    /// - `CourseDatasetWriteTools.swift`: reading an assignment's support file
    ///   to move it into the library is assignment content (TA).
    /// - `DraftAssignmentRoutes+NewAssignment.swift`: viewing a draft is a
    ///   staff read (TA).
    /// - `SuiteEditHelpers.swift`: the draft read loader is a staff read (TA).
    private static let namedOperationFiles: [String: Int] = [
        "Sources/APIServer/BrightSpace/BrightSpacePagePresenter.swift": 0,
        "Sources/APIServer/MCP/Tools/CloneAssignmentTool.swift": 0,
        "Sources/APIServer/MCP/Tools/CourseContentItemTools.swift": 0,
        "Sources/APIServer/MCP/Tools/CourseDatasetWriteTools.swift": 1,
        "Sources/APIServer/MCP/Tools/CourseSectionTools.swift": 0,
        "Sources/APIServer/MCP/Tools/CreateAssignmentTool.swift": 0,
        "Sources/APIServer/MCP/Tools/RunTournamentTool.swift": 0,
        "Sources/APIServer/MCP/Tools/SetActivityTool.swift": 0,
        "Sources/APIServer/MCP/Tools/SetAssignmentConceptTool.swift": 0,
        "Sources/APIServer/Routes/Web/CourseAdminRoutes+ContentItems.swift": 0,
        "Sources/APIServer/Routes/Web/CourseAdminRoutes+Sections.swift": 0,
        "Sources/APIServer/Routes/Web/DraftAssignmentRoutes+NewAssignment.swift": 1,
        "Sources/APIServer/Routes/Web/DraftAssignmentRoutes+SaveValidation.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+ClassActivity.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+Concept.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+Datasets.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+GitHubSubmission.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+PassingThreshold.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+SecretReveal.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes+SolutionVisibility.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorDashboardRoutes.swift": 0,
        "Sources/APIServer/Routes/Web/InstructorLMSRoutes+BrightSpace.swift": 0,
        "Sources/APIServer/Routes/Web/SuiteEditHelpers.swift": 1,
        "Sources/APIServer/Views/DashboardControls.swift": 0,
    ]

    /// The code lines of `source` that state a floor as a bare role case.
    /// Comment lines are skipped, so prose that names the syntax does not count.
    static func literalFloorLines(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return nil }
            let code = trimmed.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
            return code.contains(/atLeast:\s*\.(student|ta|instructor)\b/) ? trimmed : nil
        }
    }

    @Test(arguments: namedOperationFiles.keys.sorted())
    func fileUsesTheNamedFloors(path: String) throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
        #expect(
            source.contains("CourseRoleFloor."),
            "\(path) is listed as implementing a named operation but reads no CourseRoleFloor constant")
        let literals = Self.literalFloorLines(in: source)
        let allowed = Self.namedOperationFiles[path] ?? 0
        #expect(
            literals.count == allowed,
            """
            \(path) states \(literals.count) literal floor(s), and \(allowed) are listed as \
            deliberate. Use the CourseRoleFloor constant for a named operation, or list a new \
            one-off with its reason: \(literals)
            """)
    }

    /// The scanner sees a literal floor and ignores the named form and prose.
    @Test func scannerFindsALiteralFloor() {
        let source = """
            // A comment that names atLeast: .instructor is prose.
            let a = try await load(req, atLeast: .instructor)
            let b = try await load(req, atLeast: CourseRoleFloor.manageSections)
            let c = try await load(req, atLeast: .ta)  // trailing note
            """
        #expect(Self.literalFloorLines(in: source).count == 2)
    }
}
