import Core
import Foundation

struct RunnerProfileDetector {
    let discoveryEnabled: Bool

    /// Where jobs will actually run. The executable-output probe runs here and
    /// nowhere else — verifying `exec` in a directory jobs never use would
    /// prove nothing about the directory they do.
    var workRoot: URL = FileManager.default.temporaryDirectory

    /// Wall-clock cap on any single capability probe. Keeps a broken `python3`
    /// wrapper, an NFS stall, or a hung `which` from blocking runner startup
    /// indefinitely.
    static let probeTimeoutSeconds: Double = 5.0

    /// Wall-clock cap on a Python module-import probe. Longer than
    /// `probeTimeoutSeconds` because a cold `import pandas` loads far more than
    /// a `--version` banner, and every probe runs at once. On a loaded host the
    /// import took more than 5 s, the probe timed out, and the runner stopped
    /// advertising a module it had. `RunnerLanguageGate` then leaves every job
    /// that needs the module in the queue, with no error. A timeout is not an
    /// answer, so give the import room to finish.
    static let moduleImportTimeoutSeconds: Double = 30.0

    func detect() async -> RunnerCapabilityProfile? {
        guard discoveryEnabled else { return nil }

        // Run independent probes concurrently — capability detection used to
        // serialize ~5 subprocesses at every cold start.
        //
        // Every assignment language is probed, DISCOVERED from `allCases`
        // rather than hand-listed. The list used to be `python3` / `R` /
        // `swift`, so a runner never advertised Lua no matter what it had
        // installed — and an assignment that required `lua` matched no runner
        // at all and queued forever. A new language is advertised the day its
        // case exists.
        async let assignmentLanguageVersions = withTaskGroup(
            of: LanguageVersion?.self, returning: [LanguageVersion].self
        ) { group in
            for language in AssignmentLanguage.allCases {
                group.addTask {
                    let probe = language.interpreterProbe
                    guard
                        let version = await detectVersion(
                            command: probe.command, arguments: probe.versionArguments)
                    else { return nil }
                    // Owning the compiler is not the same as being able to run
                    // what it writes. For a language whose grading path execs
                    // its own build output, prove that here — otherwise this
                    // runner advertises a capability it does not have, the
                    // language gate routes every such job to it, and each dies
                    // at `exec` with a message that reads as a broken test
                    // script. Advertising nothing makes the job wait for a
                    // runner that can genuinely grade it, which is what the
                    // gate is for.
                    if language.descriptor.capabilityRequiresExecutableOutput,
                        await !canExecuteCompiledOutput(
                            language: language, compiler: probe.command)
                    {
                        return nil
                    }
                    return LanguageVersion(language: language.capabilityName, version: version)
                }
            }
            var found: [LanguageVersion] = []
            for await result in group {
                if let result { found.append(result) }
            }
            return found
        }
        // Swift is not an `AssignmentLanguage` — no assignment is authored in
        // it — but a runner still advertises it, so it stays a separate probe.
        async let swiftVersionOpt = detectVersion(command: "swift", arguments: ["--version"])
        async let bashExists = commandExists("bash")
        async let zshExists = commandExists("zsh")

        var languageVersions: [LanguageVersion] = await assignmentLanguageVersions
        // Build capabilities first: what this binary knows how to do,
        // independent of the host. `activity-match` says this build reads
        // `Job.opponent` and stages a class-activity opponent; a build that
        // predates it advertises nothing here, and the server's claim gate
        // leaves match jobs for one that does.
        var capabilities: Set<RunnerCapability> = Self.buildCapabilities

        if Self.probesPythonModules(given: languageVersions) {
            // Python module probes are cheap on a hit and fairly cheap on a
            // miss; run them in parallel too.
            await withTaskGroup(of: (String, Bool).self) { group in
                for module in ["numpy", "pandas", "scipy", "matplotlib"] {
                    group.addTask {
                        (module, await pythonImportAvailable(module: module))
                    }
                }
                for await (module, present) in group where present {
                    capabilities.insert(RunnerCapability(name: module))
                }
            }
        }
        if let swiftVersion = await swiftVersionOpt {
            languageVersions.append(LanguageVersion(language: "swift", version: swiftVersion))
        }
        if await bashExists {
            capabilities.insert(RunnerCapability(name: "shell-bash"))
        }
        if await zshExists {
            capabilities.insert(RunnerCapability(name: "shell-zsh"))
        }

        return RunnerCapabilityProfile(
            platform: platformName(),
            architecture: architectureName(),
            languageVersions: languageVersions.sorted { $0.language < $1.language },
            capabilities: capabilities.sorted { $0.name < $1.name }
        )
    }

    /// Whether the Python module probes run: only when the host has Python.
    /// Separate from `detect()` because every CI host has every interpreter,
    /// so no end-to-end run can tell this apart from "some language was
    /// found" — and a Python-only host would then advertise no modules.
    static func probesPythonModules(given languageVersions: [LanguageVersion]) -> Bool {
        languageVersions.contains { $0.language == AssignmentLanguage.python.capabilityName }
    }

    /// The capabilities every profile this build advertises carries, whatever
    /// the host has installed. Static so a test can pin the set without
    /// running the probes.
    static let buildCapabilities: Set<RunnerCapability> = [
        .activityMatch, .activityOpponentSubmission, .activityMatrix,
    ]

    private func platformName() -> String {
        #if os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }

    private func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func detectVersion(command: String, arguments: [String]) async -> String? {
        guard let output = await run(command: command, arguments: arguments) else { return nil }
        return firstNumericVersion(in: output)
    }

    /// The trivial program whose compilation proves this language can produce a
    /// runnable binary here, or nil when the language never produces one.
    ///
    /// EXHAUSTIVE, so an eighth language that sets
    /// `capabilityRequiresExecutableOutput` cannot reach the probe without
    /// supplying a program. The probe used to hardcode `probe.cpp` and
    /// `int main(void)` — correct while C++ was the only such language, and a
    /// silent failure for the next one: the C++ source would be handed to a
    /// different compiler, fail, and the language would never be advertised,
    /// so its jobs would queue forever with no error. That is the WORSE
    /// direction of the capability gate.
    static func execProbeProgram(
        for language: AssignmentLanguage
    ) -> (
        filename: String, source: String
    )? {
        switch language {
        case .cpp: return ("probe.cpp", "int main(void) { return 0; }\n")
        case .python, .r, .lua, .octave, .racket, .java:
            // Interpreted, or (Java) producing class files the JVM READS rather
            // than anything handed to the kernel as an executable — so `noexec`
            // cannot bite and there is nothing to prove.
            return nil
        }
    }

    /// Compiles this language's probe program into the runner's work root and
    /// runs it, mirroring what a generated C++ wrapper does (compile into the
    /// working directory, then `exec` the binary).
    ///
    /// Returns false when either step fails, including the case this exists
    /// for: the work root is mounted `noexec`, so the compile succeeds, the
    /// binary is `-rwxr-xr-x`, and `exec` still fails with EACCES. Failing
    /// closed here is deliberate — an unusable capability is worse than an
    /// absent one, because the gate trusts what a runner advertises.
    ///
    /// True for a language with no probe program: there is nothing to prove,
    /// and withholding the capability would be the fail-closed answer to a
    /// question that was never asked.
    private func canExecuteCompiledOutput(
        language: AssignmentLanguage, compiler: String
    ) async -> Bool {
        guard let program = Self.execProbeProgram(for: language) else { return true }
        let probeDir = workRoot.appendingPathComponent(
            "chickadee_exec_probe_\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        guard
            (try? fileManager.createDirectory(at: probeDir, withIntermediateDirectories: true))
                != nil
        else { return false }
        defer { try? fileManager.removeItem(at: probeDir) }

        let source = probeDir.appendingPathComponent(program.filename)
        let binary = probeDir.appendingPathComponent("probe")
        guard (try? program.source.write(to: source, atomically: true, encoding: .utf8)) != nil
        else { return false }

        guard
            await runStatus(
                command: compiler, arguments: [source.path, "-o", binary.path]) == 0
        else { return false }
        // The step the version probe never took.
        return await runStatus(command: binary.path, arguments: []) == 0
    }

    private func pythonImportAvailable(module: String) async -> Bool {
        await runStatus(
            command: "python3",
            arguments: ["-c", "import \(module)"],
            timeoutSeconds: Self.moduleImportTimeoutSeconds
        ) == 0
    }

    private func commandExists(_ command: String) async -> Bool {
        await runStatus(command: "which", arguments: [command]) == 0
    }

    private func run(command: String, arguments: [String]) async -> String? {
        guard let probe = await runProbe(command: command, arguments: arguments),
            probe.exitCode == 0
        else { return nil }
        return probe.combined.isEmpty ? nil : probe.combined
    }

    private func runStatus(
        command: String, arguments: [String], timeoutSeconds: Double = Self.probeTimeoutSeconds
    ) async -> Int32? {
        await runProbe(command: command, arguments: arguments, timeoutSeconds: timeoutSeconds)?.exitCode
    }

    /// One capability probe: `/usr/bin/env <command> <args…>`, bounded by
    /// `timeoutSeconds` (`probeTimeoutSeconds` unless the caller says), stdout and stderr collected and joined.
    ///
    /// Spawns through `swift-subprocess` rather than Foundation's `Process`.
    /// Detection runs every probe concurrently (a task group over every
    /// language), which is exactly the concurrent-spawn shape #1139 and #1233
    /// came out of, and Subprocess owns and drains the capture pipes itself --
    /// so the hand-rolled CLOEXEC pipes, deadline-bounded drain and
    /// `isRunning` poll loop this replaces have nothing left to do. The 25 ms
    /// poll is gone with them: the run now suspends until the child exits.
    private func runProbe(
        command: String, arguments: [String], timeoutSeconds: Double = Self.probeTimeoutSeconds
    ) async -> (combined: String, exitCode: Int32)? {
        let run: BoundedRunResult?
        do {
            run = try await runBounded(
                executable: "/usr/bin/env",
                arguments: [command] + arguments,
                limits: BoundedRunLimits(
                    timeout: .seconds(timeoutSeconds), outputLimit: Self.probeOutputLimitBytes,
                    teardownGrace: .milliseconds(200)))
        } catch {
            writeStructuredRunnerLog(
                event: "local_execution_error",
                fields: [
                    "error_type": "capability_detection_failed",
                    "error_message_summary": "\(command): \(error.localizedDescription)",
                ])
            return nil
        }
        guard let run else {
            writeStructuredRunnerLog(
                event: "local_execution_error",
                fields: [
                    "error_type": "capability_detection_timeout",
                    "error_message_summary": "\(command) \(arguments.joined(separator: " "))",
                    "timeout_seconds": timeoutSeconds,
                ])
            return nil
        }
        let combined = (run.standardOutput + "\n" + run.standardError)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (combined, run.exitCode)
    }

    /// Cap on a probe's captured output.  A `--version` banner is a line or
    /// two; anything approaching this is a command that ignored its arguments
    /// and started printing.
    private static let probeOutputLimitBytes = 1024 * 1024

    private func firstNumericVersion(in raw: String) -> String? {
        Self.firstNumericVersion(in: raw)
    }

    /// The first dotted version number in an interpreter's `--version` banner.
    ///
    /// INTERNAL AND STATIC so it can be tested directly. It had no test at all,
    /// and the defect below is one only a test of the real banners finds.
    ///
    /// Each whitespace token is stripped of surrounding punctuation, then any
    /// LEADING NON-DIGITS are dropped before the numeric prefix is taken. That
    /// last step is the fix: Racket's banner is `Welcome to Racket v8.10 [cs].`
    /// and its version token is `v8.10` — letter-led, which no other language's
    /// is. The prefix rule alone yielded an empty match, `detectVersion`
    /// returned nil, the runner advertised no `racket`, and `RunnerLanguageGate`
    /// then refused EVERY runner for every Racket assignment. Jobs queued
    /// forever with no error, no failed test and no log line — instructor
    /// validation included.
    ///
    /// Dropping leading non-digits is deliberately narrower than "find any
    /// dotted number in the token": a token still contributes at most its first
    /// numeric run, so `1994-2022` (Lua's copyright line) and `2023-06-16` (R's
    /// release date) stay unmatched for want of a dot, and `Lua.org` contributes
    /// nothing for want of a digit. Every language's banner is pinned in
    /// `RunnerProfileDetectorTests`.
    static func firstNumericVersion(in raw: String) -> String? {
        for token in raw.split(whereSeparator: \.isWhitespace) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]"))
            let fromFirstDigit = cleaned.drop { !$0.isNumber }
            let numericPrefix = fromFirstDigit.prefix { $0.isNumber || $0 == "." }
            if !numericPrefix.isEmpty, numericPrefix.contains(".") {
                return String(numericPrefix)
            }
        }
        return nil
    }
}
