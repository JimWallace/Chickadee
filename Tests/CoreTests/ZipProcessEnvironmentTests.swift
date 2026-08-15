import Foundation
import Testing

@testable import Core

/// Guards the environment snapshot that keeps zip subprocesses from reading the
/// global environ at spawn time.
///
/// The failure this prevents is not a test failure — it is a SIGSEGV. A
/// `Process` with a nil `environment` reads the global environ itself when it
/// spawns, racing `setenv`/`unsetenv` from the suites that mutate environment
/// variables. When the kernel notices the bad address the EFAULT retry absorbs
/// it; when the read walks a reallocated environ in user space, the process
/// dies mid-run and there is nothing to catch.
///
/// That makes this exactly the kind of regression a normal test cannot see: a
/// new bare `Process()` on the zip path would opt back into the crash with every
/// other test still green, and the crash it opts into is rare and lands on
/// whichever unrelated pull request happens to be running.
@Suite("Zip process environment")
struct ZipProcessEnvironmentTests {

    /// The property the factory exists to supply, pinned as a property of
    /// Foundation rather than assumed.
    ///
    /// Without this, every assertion below would still pass if Foundation
    /// started defaulting `environment` to the parent's — and the factory would
    /// be guarding something that no longer needed guarding, with no way to
    /// tell.
    @Test("a bare Process really does start with no environment")
    func bareProcessHasNilEnvironment() {
        #expect(Process().environment == nil)
    }

    @Test("the factory hands back a Process that will not read environ at spawn")
    func factorySetsEnvironment() throws {
        let env = try #require(makeZipProcess().environment)
        #expect(!env.isEmpty, "an empty snapshot would change what the child inherits")
    }

    /// Snapshot, not re-read: the point is one read per process rather than one
    /// per spawn, so two calls must hand back the same contents.
    @Test("the snapshot is taken once, not per call")
    func snapshotIsStable() throws {
        let first = try #require(makeZipProcess().environment)
        let second = try #require(makeZipProcess().environment)
        #expect(first == second)
    }

    /// The contents are whatever these spawns inherited before, so nothing about
    /// their behaviour changes — only the number of racy reads.
    @Test("the snapshot is the parent environment, not a substitute for it")
    func snapshotMatchesParent() throws {
        let env = try #require(makeZipProcess().environment)
        let parent = ProcessInfo.processInfo.environment
        // PATH is the one every spawn here actually depends on.
        #expect(env["PATH"] == parent["PATH"])
    }

    /// The drift guard.
    ///
    /// Two exemptions, both of which this guard needed in order to stop
    /// matching itself:
    ///
    ///   * a match preceded by an identifier character is part of a longer name
    ///     (`makeZipProcess`, `runZipProcess`), not a construction;
    ///   * the factory's own BODY holds the one legitimate construction —
    ///     exempting its signature line is not enough, since the construction is
    ///     on the next one.
    ///
    /// Comment lines are skipped for the same reason: prose describing a
    /// forbidden construction is not one, and a scanner that cannot tell the
    /// difference is how #1266's Leaf finding went wrong.
    @Test("no zip source constructs a Process directly")
    func zipSourcesUseTheFactory() throws {
        let sources = ["Sources/Core/ZipArchiver.swift", "Sources/Core/ZipProcessSerialization.swift"]
        // The factory's own body holds the one legitimate construction, so it
        // is exempt — but only its body. Matching the signature LINE is not
        // enough: the construction is on the next one, which is how the first
        // version of this guard failed, correctly, against itself.
        let factorySignature = "public func makeZipProcess() -> Process {"
        var insideFactory = false

        for relative in sources {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // CoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)

            var offending: [Int] = []
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains(factorySignature) { insideFactory = true }
                else if insideFactory && line == "}" { insideFactory = false }
                guard let range = line.range(of: "Process(") else { continue }
                // Preceded by an identifier character → part of a longer name
                // (makeZipProcess, runZipProcess…), not a construction.
                if range.lowerBound > line.startIndex {
                    let before = line[line.index(before: range.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                // Comments describe the rule; they do not break it. Naming the
                // forbidden construction in prose is how a scanner that cannot
                // tell markup from prose about markup gets it wrong (#1266).
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if insideFactory { continue }
                offending.append(index + 1)
            }

            #expect(
                offending.isEmpty,
                """
                \(relative) constructs a Process directly at line(s) \(offending). \
                Use makeZipProcess(): a bare Process has a nil environment, which \
                makes the spawn read the global environ and race setenv.
                """)
        }
    }
}
