// Tests/WorkerTests/RunCommandMatchesInvocationTests.swift
//
// `LanguageDescriptor.scriptRunCommand` must be the command the worker actually
// spawns for that language's source files.
//
// The descriptor exists in Core, the invocation table in Worker, and only this
// target can see both — which is why the two drifted in the first place. R's
// entry claimed the probe command `R` was also the run command, on the stated
// reasoning that "the runner spawns the probed interpreter on a script, so
// probing IS invoking". For R it does not: `Rscript` runs a file, `R` reads a
// REPL from stdin and prints that the filename argument was ignored. The shell
// test-script scaffold believed the descriptor and handed every R author a
// command that cannot run.
//
// The guard is per-language and derived from `allCases`, so a seventh language
// is covered the day it is added.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct RunCommandMatchesInvocationTests {

    /// Compiled languages are excluded, and the exclusion is derived rather
    /// than spelled `.cpp`: `capabilityRequiresExecutableOutput` already means
    /// "grading this builds something before running it", so its source file
    /// is handed to a compiler by a generated wrapper, not spawned directly.
    @Test(arguments: AssignmentLanguage.allCases)
    func theRunCommandIsWhatTheWorkerSpawns(_ language: AssignmentLanguage) throws {
        guard !language.descriptor.capabilityRequiresExecutableOutput else { return }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("solution.\(language.sourceFileExtension)")
        try Data("\n".utf8).write(to: script)

        let invocation = scriptInvocation(for: script)
        // `env` is the spawn shape for most of these, so the interpreter is an
        // argument rather than the executable — check both places.
        let named =
            invocation.executableURL.lastPathComponent == language.descriptor.scriptRunCommand
            || invocation.arguments.contains(language.descriptor.scriptRunCommand)
        #expect(
            named,
            """
            \(language) declares scriptRunCommand \
            "\(language.descriptor.scriptRunCommand)" but the worker spawns \
            \(invocation.executableURL.lastPathComponent) \(invocation.arguments).
            """)
    }
}
