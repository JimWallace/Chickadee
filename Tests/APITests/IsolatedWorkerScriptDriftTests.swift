// Tests/APITests/IsolatedWorkerScriptDriftTests.swift
//
// `NotebookAssetIsolationMiddleware.isolatedWorkerScripts` is a hand-maintained
// list of the Web Worker scripts the cross-origin-ISOLATED notebook page spawns.
// A worker missing from it is refused by the browser outright
// (`ERR_BLOCKED_BY_RESPONSE`), because a dedicated worker created by a
// `require-corp` document must itself be served with COEP.
//
// That list has drifted twice, and neither time did anything in CI notice:
//
//   * #1274 added `/r-grading-worker.js` and did not add it here, so browser
//     grading of R was blocked on every isolated engine and silently failed the
//     submission over to the native worker.
//   * #1271 replaced `/grading-worker.js` with a per-language pair, leaving the
//     list pointing at a file that no longer exists.
//
// Both are invisible to the rest of the suite: no Swift test spawns a worker,
// and the browser-grading smoke harness page is not isolated, so it cannot
// reproduce the block either. The editor smoke test does catch it — but only in
// a real Chromium, minutes into CI, and only for whichever single worker its
// probe happens to name.
//
// So this reads the spawn sites out of the page scripts instead, and asserts the
// list matches them in BOTH directions: nothing spawned is missing (the #1274
// bug) and nothing listed is stale (the #1271 bug).
//
// Only the scripts loaded by the isolated pages are scanned. `pyodide-worker.js`
// is spawned by the assignment-editor pages, which are deliberately NOT isolated
// — forcing `require-corp` on it would be a regression, not a fix — so its
// spawn site lives in a file this test does not read.

import Foundation
import Testing

@testable import APIServer

@Suite struct IsolatedWorkerScriptDriftTests {

    /// Page scripts that run inside the cross-origin-isolated notebook page.
    /// Every `new Worker(...)` in one of these is a worker the isolated page
    /// spawns, and therefore needs COEP.
    private static let isolatedPageScripts = [
        "Public/browser-runner.js",  // grading workers, one per language
        "Public/notebook.js",  // freeze-watchdog failover
    ]

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    /// Worker script paths spawned by `source`.
    ///
    /// Matches the two call shapes that name a script literally —
    /// `new Worker('/x.js')` and browser-runner's `gradingWorkerFactory('/x.js')`
    /// wrapper — and ignores the indirect `new Worker(scriptPath + v)` inside
    /// that wrapper, which has no literal to check.
    ///
    /// Comment lines are stripped first. These files carry long banner comments
    /// that name worker paths in prose, and a scanner that cannot tell code from
    /// prose about code reports whatever the documentation happens to mention.
    private func spawnedWorkerScripts(in source: String) -> Set<String> {
        let code =
            source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
            }
            .joined(separator: "\n")

        let pattern = #"(?:new\s+Worker|gradingWorkerFactory)\(\s*['"](/[^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        var found: Set<String> = []
        for match in regex.matches(in: code, range: range) {
            guard let captured = Range(match.range(at: 1), in: code) else { continue }
            found.insert(String(code[captured]))
        }
        return found
    }

    private func readIsolatedPageScripts() throws -> [String: Set<String>] {
        var byFile: [String: Set<String>] = [:]
        for relative in Self.isolatedPageScripts {
            let url = Self.repoRoot.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            byFile[relative] = spawnedWorkerScripts(in: source)
        }
        return byFile
    }

    @Test func everyWorkerTheIsolatedPageSpawnsIsAllowlisted() throws {
        let spawned = try readIsolatedPageScripts()
        // Guard the scanner itself: a regex that silently stops matching would
        // otherwise turn this test into a no-op that passes forever.
        for (file, paths) in spawned {
            #expect(!paths.isEmpty, "found no worker spawn sites in \(file) — the scanner is broken")
        }

        for (file, paths) in spawned {
            for path in paths.sorted() {
                #expect(
                    NotebookAssetIsolationMiddleware.isolatedWorkerScripts.contains(path),
                    """
                    \(file) spawns \(path) from the cross-origin-isolated notebook page, but it is \
                    not in NotebookAssetIsolationMiddleware.isolatedWorkerScripts. Without COEP on \
                    the worker script the browser refuses to start the worker \
                    (ERR_BLOCKED_BY_RESPONSE) and browser grading fails over to the native worker.
                    """)
            }
        }
    }

    @Test func noAllowlistedWorkerIsStale() throws {
        let spawned = Set(try readIsolatedPageScripts().values.joined())
        for path in NotebookAssetIsolationMiddleware.isolatedWorkerScripts.sorted() {
            #expect(
                spawned.contains(path),
                """
                NotebookAssetIsolationMiddleware.isolatedWorkerScripts lists \(path), but no \
                isolated page script spawns it. Either it was renamed or deleted and the entry \
                was left behind, or it is now spawned from a file not in isolatedPageScripts — \
                in which case add that file here.
                """)
        }
    }

    /// Every allowlisted worker must actually be servable, or COEP is being
    /// stamped on a 404.
    @Test func everyAllowlistedWorkerFileExists() throws {
        for path in NotebookAssetIsolationMiddleware.isolatedWorkerScripts.sorted() {
            let url = Self.repoRoot.appendingPathComponent("Public" + path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "isolatedWorkerScripts lists \(path), but Public\(path) does not exist")
        }
    }
}
