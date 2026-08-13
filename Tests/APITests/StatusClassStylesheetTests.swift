// Tests/APITests/StatusClassStylesheetTests.swift
//
// submission.leaf builds class names by interpolation —
// `status-#(outcome.status)` on every outcome row and
// `result-mark-#(outcome.markClass)` on every mark chip — so the stylesheet
// rules those names resolve to are invisible to the compiler AND to the
// static style guards (check-styles.sh scans selectors, not the interpolated
// names templates mint at render time).
//
// The failure mode this pins down: adding a fifth `TestStatus` case ships an
// outcome row with no colour strip and a mark chip with no styling, and
// nothing anywhere fails.  The dead `test-output-row-<status>` family removed
// in the UI-rendering-rules pass shipped exactly that way.
//
// `TestStatus` is `CaseIterable`, so a new case lands in `allCases`
// automatically and this test names the missing selector on the PR that
// introduces it.  `skipped` is not a `TestStatus` — it is the presenter's
// extra markClass/row state for dependency-skipped tests
// (SubmissionResultPresenter.swift) — so it is asserted alongside.

import Core
import Foundation
import Testing

@Suite struct StatusClassStylesheetTests {

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private static func globalStylesheet() throws -> String {
        let url = repoRoot.appendingPathComponent("Public/styles.css")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every markClass value the presenter can emit: the four `TestStatus`
    /// raw values plus the dependency-skip state.
    private static var markClasses: [String] {
        TestStatus.allCases.map(\.rawValue) + ["skipped"]
    }

    @Test func statusRowSelectorExistsForEveryStatus() throws {
        let css = try Self.globalStylesheet()
        for name in Self.markClasses {
            #expect(
                css.contains(".status-\(name)"),
                "Public/styles.css defines no .status-\(name) — submission.leaf mints this class for every outcome row"
            )
        }
    }

    @Test func resultMarkSelectorExistsForEveryMarkClass() throws {
        let css = try Self.globalStylesheet()
        for name in Self.markClasses {
            #expect(
                css.contains(".result-mark-\(name)"),
                "Public/styles.css defines no .result-mark-\(name) — submission.leaf mints this class for every mark chip"
            )
        }
    }
}
