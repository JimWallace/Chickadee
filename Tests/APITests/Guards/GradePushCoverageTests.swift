// Architectural guard for the LMS grade-push fan-out (#2259, item 2).
//
// A change to a grade must reach both LMS integrations, BrightSpace Valence and
// LTI AGS. `requestGradePush` is the one place that asks both. This test fails
// when a file outside it calls one integration's per-grade request directly,
// because that is how a trigger asks one LMS and forgets the other. The browser
// result path once did exactly that: it never set the BrightSpace flag, so
// notebook labs never pushed to LEARN on their own.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import APIServer

@Suite struct GradePushCoverageTests {
    private static var sourcesDirectory: URL {
        repositoryRoot.appendingPathComponent("Sources/APIServer")
    }

    /// The per-integration requests that a grade change must make in pairs.
    private static let perIntegrationCalls = [
        "LTIGradeSyncQueue.queue(",
        "LTIGradeSyncQueue.queueAllStudents(",
        "flagResultForBrightSpaceSync(",
        "flagStudentForBrightSpaceSync(",
        "requeueFrozenClassGoalBonusPushes(",
    ]

    /// Files that may make a per-integration call, with the reason.
    private static let allowedFiles: Set<String> = [
        // The fan-out itself.
        "GradePushRequest.swift",
        // The instructor's manual "Push all" for LTI grades: a button that
        // belongs to one integration. BrightSpace has its own.
        "InstructorLMSRoutes+LTIGrades.swift",
    ]

    @Test func perIntegrationGradeRequestsGoThroughRequestGradePush() throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: Self.sourcesDirectory, includingPropertiesForKeys: nil)
        else {
            throw IssueRecorded("Cannot list \(Self.sourcesDirectory.path)")
        }
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let name = file.lastPathComponent
            guard !Self.allowedFiles.contains(name) else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Comments mention the functions; declarations define them.
                    return !trimmed.hasPrefix("//") && !trimmed.contains("func ")
                }
            for call in Self.perIntegrationCalls {
                let hits = lines.filter { $0.contains(call) }
                #expect(
                    hits.isEmpty,
                    """
                    \(name) calls \(call.dropLast()) directly. A grade change must reach both \
                    LMS integrations: call requestGradePush (GradePushRequest.swift) instead.
                    """)
            }
        }
        #expect(scanned > 0)
    }
}
