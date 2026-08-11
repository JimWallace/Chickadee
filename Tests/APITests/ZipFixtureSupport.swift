// Tests/APITests/ZipFixtureSupport.swift
//
// The one place tests shell out to `/usr/bin/zip`.
//
// WHY IT IS A HELPER AND NOT SEVENTEEN COPIES. Foundation's `Process` has a
// known race under concurrent invocation — documented, and already mitigated in
// production, by `Core/ZipProcessSerialization.swift`:
//
//     The race spans more than just `posix_spawn` itself — Pipe allocation,
//     child fd setup, and spawn all share global state — and reaches across the
//     whole Process API surface.
//
// That file exists because naked `Process.run()` calls once raced against
// `ZipArchiver`'s lock-protected ones "and against each other". Seventeen test
// fixtures then reintroduced exactly that, each building its own `Process` and
// spawning it unlocked, and under `swift test --parallel` they crashed the test
// process inside `Process.run()`:
//
//     Thread 1 crashed: __memmove_evex_unaligned_erms
//       Process.run()
//       AuthorScriptToolTests.writeZip(at:entries:)
//
// It looked like the environment race that shared these symptoms, and it is a
// separate bug with a separate cause: it survived the removal of every `setenv`
// in the suite.
//
// The lock has to cover CONSTRUCTION, not just the spawn — that is what the
// header above means by "the whole Process API surface" — so the `Process` and
// its `Pipe`s are built inside the closure rather than handed to it.

import Core
import Foundation
import Testing

/// Zips the contents of `directory` into `zipPath`, serialized against every
/// other zip subprocess in the process.
///
/// Mirrors what the seventeen hand-rolled fixtures did — `zip -q -r <path> .`
/// with the working directory set — including asserting the exit status, which
/// most of them did and a few silently skipped.
func writeZipFixture(
    of directory: URL,
    to zipPath: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let status = try withZipProcessLock { () throws -> Int32 in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", zipPath, "."]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #expect(status == 0, "zip command must succeed", sourceLocation: sourceLocation)
}
