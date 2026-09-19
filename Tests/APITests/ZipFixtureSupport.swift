// Tests/APITests/ZipFixtureSupport.swift
//
// The one place tests shell out to `/usr/bin/zip`.
//
// WHY IT IS A HELPER AND NOT SEVENTEEN COPIES. Foundation's `Process` had a
// race under concurrent invocation that spanned the whole API surface — Pipe
// allocation, child fd setup and spawn all share global state — not just
// `posix_spawn`. Seventeen test fixtures each built their own `Process` and
// spawned it, and under `swift test --parallel` they crashed the test process
// inside `Process.run()`:
//
//     Thread 1 crashed: __memmove_evex_unaligned_erms
//       Process.run()
//       AuthorScriptToolTests.writeZip(at:entries:)
//
// It looked like the environment race that shared these symptoms, and it was a
// separate bug with a separate cause: it survived the removal of every `setenv`
// in the suite.
//
// Production answered that race with a process-wide lock around construction
// and spawn, and this helper existed to keep the fixtures inside that regime.
// The lock is gone now: zip spawns run on `swift-subprocess`, which does not
// share the global state the race lived in. One helper is still the right
// shape — it asserts the exit status, which most of the seventeen did and a
// few silently skipped — but it no longer carries a serialization contract.

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
) async throws {
    let result = try await runZipProcess(
        executablePath: "/usr/bin/zip",
        arguments: ["-q", "-r", zipPath, "."],
        workingDirectory: directory
    )
    #expect(
        result.terminationStatus == 0, "zip command must succeed",
        sourceLocation: sourceLocation)
}
