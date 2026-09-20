import Core
import Foundation
import Testing

/// Guards the environment snapshot that keeps zip subprocesses from reading the
/// global environ at spawn time.
///
/// The failure this prevents is not a test failure — it is a SIGSEGV. A spawn
/// that lets the library read the environment for it becomes an unsynchronized
/// reader of a structure `setenv`/`unsetenv` reallocates, and several suites
/// mutate environment variables while Swift Testing runs them concurrently.
/// The observed crash was in `_ProcessInfo.environment.getter` under
/// `Process.run()`, reported as `Bad pointer dereference at 0x210`.
///
/// Moving the spawn to `swift-subprocess` did not retire this concern, it
/// renamed it: Subprocess defaults to `.inherit`, and a call that omits
/// `environment:` opts straight back into the per-spawn read. That makes this
/// exactly the kind of regression a normal test cannot see — every other test
/// stays green, and the crash it opts into is rare and lands on whichever
/// unrelated pull request happens to be running.
@Suite("Zip process environment")
struct ZipProcessEnvironmentTests {

    private func zipSource(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The behavioural half: a child really does receive the parent's
    /// environment. The snapshot is an optimisation over reading environ per
    /// spawn, not a substitute for inheriting it, and a snapshot that came back
    /// empty would silently change what every zip child sees.
    @Test(
        "a zip spawn receives the parent environment",
        .enabled(if: FileManager.default.fileExists(atPath: "/usr/bin/env"), "requires /usr/bin/env"))
    func spawnInheritsParentEnvironment() async throws {
        let parentPath = try #require(ProcessInfo.processInfo.environment["PATH"])

        let result = try await runZipProcess(executablePath: "/usr/bin/env", arguments: [])
        #expect(result.terminationStatus == 0)
        let text = try #require(String(bytes: result.stdout, encoding: .utf8))
        #expect(text.contains("PATH=\(parentPath)"))
    }

    /// The drift guard, in the direction that now matters.
    ///
    /// `.inherit` is Subprocess's default, so the hazard is an OMITTED
    /// `environment:` argument rather than a bare `Process()`. Pinning the
    /// explicit `.custom(` is what a future call site has to keep true.
    @Test("the zip spawn passes an explicit environment")
    func spawnPassesExplicitEnvironment() throws {
        let text = try zipSource("Sources/Core/ZipSubprocess.swift")
        #expect(
            text.contains("environment: .custom(zipProcessEnvironment)"),
            """
            ZipSubprocess.swift no longer passes an explicit environment. \
            Subprocess defaults to .inherit, which reads the environment at \
            spawn time and races setenv.
            """)
    }

    /// Foundation's `Process` is what carried the per-spawn environ read and
    /// the EFAULT race. Nothing on the zip path may go back to it.
    ///
    /// Comment lines are skipped: prose describing a forbidden construction is
    /// not one, and a scanner that cannot tell the difference is how #1266's
    /// Leaf finding went wrong.
    @Test("no zip source constructs a Foundation Process")
    func zipSourcesDoNotUseFoundationProcess() throws {
        for relative in ["Sources/Core/ZipArchiver.swift", "Sources/Core/ZipSubprocess.swift"] {
            let text = try zipSource(relative)
            var offending: [Int] = []
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                guard let range = line.range(of: "Process(") else { continue }
                // Preceded by an identifier character → part of a longer name
                // (runZipProcess…), not a construction.
                if range.lowerBound > line.startIndex {
                    let before = line[line.index(before: range.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                offending.append(index + 1)
            }
            #expect(
                offending.isEmpty,
                """
                \(relative) constructs a Foundation Process at line(s) \(offending). \
                Zip spawns go through runZipProcess, which uses swift-subprocess: \
                Process carries the per-spawn environ read and the EFAULT race.
                """)
        }
    }
}
