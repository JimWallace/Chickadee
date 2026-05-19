// Tests/APITests/WebAssignmentErrorTests.swift
//
// Tests for `WebAssignmentError` (issue #442 typed-errors migration):
//
//   1. Each enum case maps to the expected HTTP status, so future tweaks
//      to the switch statement can't silently drop a status code.
//
//   2. The instructor assignment-route files contain zero `throw Abort(`
//      sites, locking in the migration so a future copy-paste regression
//      gets caught at PR time instead of in production traffic.

import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct WebAssignmentErrorTests {

    // MARK: - (i) Enum → HTTP status mapping

    /// Walks every `WebAssignmentError` case and asserts the rendered
    /// `status` matches the contract documented on each case.  Catches
    /// mistakes like `case .conflict: return .badRequest` that the
    /// compiler can't.  Sample reasons keep the test tautology-free —
    /// the assertion is on `status`, not `reason`.
    @Test(
        arguments: [
            (WebAssignmentError.notFound(resource: "Assignment 'abc'"), HTTPResponseStatus.notFound),
            (.invalidParameter(name: "draftID", reason: "missing"), .badRequest),
            (.noActiveCourse(action: "creating an assignment"), .badRequest),
            (.forbidden(action: "edit assignments"), .forbidden),
            (.conflict(reason: "duplicate filename"), .conflict),
            (.unprocessable(reason: "Section variable name is not a valid Python identifier."), .unprocessableEntity),
            (.validationRequired(reason: "validation has not passed"), .badRequest),
            (.internalFailure(reason: "Failed to package setup zip"), .internalServerError),
        ] as [(WebAssignmentError, HTTPResponseStatus)])
    func statusForCase(_ error: WebAssignmentError, _ expected: HTTPResponseStatus) {
        #expect(error.status == expected)
    }

    // MARK: - (iii) No raw `Abort(...)` left in scope

    /// The instructor assignment routes were migrated to
    /// `WebAssignmentError` in v0.4.143 (#442).  This test fails if any
    /// in-scope file regresses to `throw Abort(`.  Out-of-scope Web
    /// routes (EnrollmentRoutes, CourseBundleRoutes, AccountRoutes,
    /// AdminRoutes*) are deliberately not checked — they have their
    /// own typed-error work in flight.
    @Test
    func noRawAbortInInstructorAssignmentRoutes() throws {
        let inScope: [String] = [
            "AssignmentHelpers.swift",
            "AssignmentDraftHelpers.swift",
            "AssignmentRequirementHelpers.swift",
            "AssignmentSlugHelpers.swift",
            "ManifestFileHelpers.swift",
            "MultipartHelpers.swift",
            "NotebookScaffoldHelpers.swift",
            "RunnerValidationHelpers.swift",
            "SuiteRowHelpers.swift",
            "TestSetupZipHelpers.swift",
            "SuiteEditHelpers.swift",
            "AssignmentRoutes.swift",
            "AssignmentRoutes+Checks.swift",
            "AssignmentRoutes+Draft.swift",
            "AssignmentRoutes+DraftSections.swift",
            "AssignmentRoutes+Editor.swift",
            "AssignmentRoutes+Enrollment.swift",
            "AssignmentRoutes+Families.swift",
            "AssignmentRoutes+List.swift",
            "AssignmentRoutes+NewPage.swift",
            "AssignmentRoutes+SaveValidation.swift",
            "AssignmentRoutes+Sections.swift",
            "AssignmentRoutes+Submissions.swift",
            "AssignmentRoutes+Suite.swift",
            "AssignmentRoutes+SuiteSections.swift",
        ]

        let webDir = sourceWebRoutesDirectory()
        var offenders: [String] = []
        for filename in inScope {
            let path = webDir.appendingPathComponent(filename).path
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                Issue.record("In-scope file missing from disk: \(filename)")
                continue
            }
            if source.contains("throw Abort(") {
                offenders.append(filename)
            }
        }

        #expect(
            offenders.isEmpty,
            "These files regressed to `throw Abort(` instead of `WebAssignmentError`: \(offenders.joined(separator: ", "))"
        )
    }

    /// Walks up from this test's `#filePath` to the project root and
    /// returns the `Sources/APIServer/Routes/Web/` directory.  Avoids
    /// hard-coding an absolute path so the test runs in any checkout
    /// (CI, worktree, etc.).
    private func sourceWebRoutesDirectory(file: StaticString = #filePath) -> URL {
        // #filePath is …/Tests/APITests/WebAssignmentErrorTests.swift
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // .../Tests/APITests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("Sources/APIServer/Routes/Web", isDirectory: true)
    }
}
