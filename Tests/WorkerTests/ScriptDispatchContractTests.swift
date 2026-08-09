import Core
import Foundation
import Testing

@testable import chickadee_runner

// Script-dispatch regression table (worker side).
//
// `scriptInvocation` (Sources/Worker/ScriptInvocation.swift) decides "how do I
// run this test script?". It has drifted from the browser's `classifyScript`
// twice — most recently extensionless Python scripts being reported as
// unsupported in the browser while the worker ran them fine (#754) — and this
// fixture is what pins the worker half against regressing.
//
// IT IS NOT A CROSS-RUNNER CONTRACT ANY MORE, whatever this header used to say.
// It claimed the browser side was pinned to the same fixture by
// Tests/BrowserRunnerJSTests/script-dispatch-contract.test.mjs; that file no
// longer exists, and nothing outside this suite reads
// Tests/Fixtures/script-dispatch-cases.json. Restoring a browser twin is worth
// doing — the browser now routes four substrates off the same classification —
// but a comment asserting a guard that is not there is worse than no comment,
// so this says what is actually true.
//
// The rows are hand-written, which is fine for the shapes that have no language
// (extensionless, shebang-only, content-sniffed). It is NOT fine for the one
// row per language that has to exist, so that half is asserted from `allCases`
// below rather than trusted to whoever last edited the JSON.
@Suite struct ScriptDispatchContractTests {

    private struct DispatchCase: Decodable {
        let name: String
        let content: String
        let kind: String
        let note: String
    }

    private struct Fixture: Decodable {
        let cases: [DispatchCase]
    }

    // .../Tests/WorkerTests/ScriptDispatchContractTests.swift -> repo root
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    // Collapse a concrete ScriptInvocation down to a coarse vocabulary:
    // "python" / "r" / "lua" / "octave" / "shell". Anything else maps to
    // "other" so an unexpected match fails loudly against the fixture.
    //
    // Lua and Octave are named rather than left in "other" because a fixture
    // row asserting "other" pins almost nothing — `.lua` dispatching to
    // `octave-cli` would satisfy it. They collapsed to "other" only because no
    // row had ever exercised them.
    private func kind(of invocation: ScriptInvocation) -> String {
        let exe = invocation.executableURL.lastPathComponent
        let first = invocation.arguments.first
        if first == "python3" { return "python" }
        if first == "Rscript" { return "r" }
        if first == "lua" { return "lua" }
        if first == "octave-cli" { return "octave" }
        if first == "racket" { return "racket" }
        if exe == "sh" || first == "bash" || first == "zsh" { return "shell" }
        return "other"
    }

    /// Languages deliberately absent from the fixture, each with its reason —
    /// a NAMED EXEMPTION rather than a skip, so an absence is one somebody
    /// chose with the reason greppable beside it.
    ///
    /// EMPTY, and that is the point. Racket sat here while its generated
    /// `.rkt` had no `ScriptInterpreter` case and fell through to `/bin/sh`;
    /// the exemption was written to come out WITH the fix, and it has. A
    /// non-empty map now means someone has a language whose generated scripts
    /// nothing pins — which is what this file exists to prevent.
    static let fixtureExemptions: [AssignmentLanguage: String] = [:]

    /// Every language's generated scripts have a fixture row.
    ///
    /// The half of this file that cannot be left to a hand-written JSON list.
    /// A language absent from the fixture is a language whose dispatch nothing
    /// pins — and the failure is silent, because the remaining rows still pass.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageHasADispatchRow(_ language: AssignmentLanguage) throws {
        if let reason = Self.fixtureExemptions[language] {
            // Visible rather than skipped: the reason is part of the output.
            #expect(!reason.isEmpty, "\(language) is exempt for no stated reason")
            return
        }
        let fixtureURL = repoRoot()
            .appendingPathComponent("Tests/Fixtures/script-dispatch-cases.json")
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: fixtureURL))
        let suffix = ".\(language.generatedScriptExtension.lowercased())"
        #expect(
            fixture.cases.contains { $0.name.lowercased().hasSuffix(suffix) },
            """
            No row in Tests/Fixtures/script-dispatch-cases.json exercises \
            \(suffix), the extension \(language)'s generated tests carry. Nothing pins how the \
            runner dispatches them, and the other rows still pass — add a row, or add \
            \(language) to `fixtureExemptions` with a reason.
            """)
    }

    @Test func workerDispatchMatchesSharedContract() throws {
        let fixtureURL = repoRoot()
            .appendingPathComponent("Tests/Fixtures/script-dispatch-cases.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chickadee-dispatch-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for testCase in fixture.cases {
            let scriptURL = tempDir.appendingPathComponent(testCase.name)
            try testCase.content.write(to: scriptURL, atomically: true, encoding: .utf8)

            let resolved = kind(of: scriptInvocation(for: scriptURL))
            #expect(
                resolved == testCase.kind,
                """
                Dispatch contract violated for "\(testCase.name)" (\(testCase.note)): worker \
                scriptInvocation produced "\(resolved)" but the shared fixture \
                (Tests/Fixtures/script-dispatch-cases.json) requires "\(testCase.kind)". If you \
                changed the rules, update both runners (Sources/Worker/ScriptInvocation.swift and \
                Public/browser-runner.js) and the fixture together.
                """)
        }
    }
}
