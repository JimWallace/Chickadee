import Foundation
import Testing

@testable import chickadee_runner

// Guards against the runtime helpers drifting between their three copies:
//   * Tools/runner-support/test_runtime.py / .R / sitecustomize.py  (canonical)
//   * Sources/Worker/TestRuntimeSources.swift  (native worker embeds these)
//   * Public/browser-runner.js                 (the browser runner embeds these)
//
// The Swift side is checked here against the canonical files; the JS side is
// checked by Tests/BrowserRunnerJSTests/runtime-drift.test.mjs.  Comparison is
// over executable code only — blank lines and full-line comments are ignored,
// since the embeds intentionally omit some documentation comments but MUST keep
// identical behaviour.
@Suite struct RuntimeSourceDriftTests {

    private func rstrip(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev] == " " || s[prev] == "\t" { end = prev } else { break }
        }
        return String(s[..<end])
    }

    private func normalizedCode(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter {
                let s = $0.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && !s.hasPrefix("#")
            }
            .map { rstrip($0) }
            .joined(separator: "\n")
    }

    private func canonical(_ relativePath: String) throws -> String {
        // .../Tests/WorkerTests/RuntimeSourceDriftTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func testRuntimePyMatchesCanonical() throws {
        let canon = try canonical("Tools/runner-support/test_runtime.py")
        #expect(
            normalizedCode(testRuntimePy) == normalizedCode(canon),
            """
            `testRuntimePy` in Sources/Worker/TestRuntimeSources.swift has drifted from \
            Tools/runner-support/test_runtime.py. Re-sync both copies (and the \
            TEST_RUNTIME_PY literal in Public/browser-runner.js).
            """)
    }

    @Test func testRuntimeRMatchesCanonical() throws {
        let canon = try canonical("Tools/runner-support/test_runtime.R")
        #expect(
            normalizedCode(testRuntimeR) == normalizedCode(canon),
            "`testRuntimeR` has drifted from Tools/runner-support/test_runtime.R. Re-sync.")
    }

    @Test func sitecustomizePyMatchesCanonical() throws {
        let canon = try canonical("Tools/runner-support/sitecustomize.py")
        #expect(
            normalizedCode(sitecustomizePy) == normalizedCode(canon),
            """
            `sitecustomizePy` has drifted from Tools/runner-support/sitecustomize.py. \
            Re-sync both copies (and the SITECUSTOMIZE_PY literal in Public/browser-runner.js).
            """)
    }
}
