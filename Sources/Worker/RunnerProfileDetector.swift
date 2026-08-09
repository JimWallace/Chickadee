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
                        await !canExecuteCompiledOutput(compiler: probe.command)
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
        var capabilities: Set<RunnerCapability> = []

        if languageVersions.contains(where: { $0.language == AssignmentLanguage.python.capabilityName }) {
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

    /// Compiles a trivial program into the runner's work root and runs it,
    /// mirroring what a generated C++ wrapper does (compile into the working
    /// directory, then `exec` the binary).
    ///
    /// Returns false when either step fails, including the case this exists
    /// for: the work root is mounted `noexec`, so the compile succeeds, the
    /// binary is `-rwxr-xr-x`, and `exec` still fails with EACCES. Failing
    /// closed here is deliberate — an unusable capability is worse than an
    /// absent one, because the gate trusts what a runner advertises.
    private func canExecuteCompiledOutput(compiler: String) async -> Bool {
        let probeDir = workRoot.appendingPathComponent(
            "chickadee_exec_probe_\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        guard
            (try? fileManager.createDirectory(at: probeDir, withIntermediateDirectories: true))
                != nil
        else { return false }
        defer { try? fileManager.removeItem(at: probeDir) }

        let source = probeDir.appendingPathComponent("probe.cpp")
        let binary = probeDir.appendingPathComponent("probe")
        guard (try? "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)) != nil
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
            arguments: ["-c", "import \(module)"]
        ) == 0
    }

    private func commandExists(_ command: String) async -> Bool {
        await runStatus(command: "which", arguments: [command]) == 0
    }

    private func run(command: String, arguments: [String]) async -> String? {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        // CLOEXEC + bounded drain: a non-CLOEXEC write end inherited by a
        // concurrently spawned process postpones EOF until *that* process
        // exits, turning `readDataToEndOfFile()` into an unbounded stall on
        // a cooperative-pool thread (issue #1233; same mechanism as #1139).
        setCloseOnExec(output)
        setCloseOnExec(error)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            writeStructuredRunnerLog(
                event: "local_execution_error",
                fields: [
                    "error_type": "capability_detection_failed",
                    "error_message_summary": "\(command): \(error.localizedDescription)",
                ])
            return nil
        }

        let exited = await waitWithTimeout(process: process, command: command, arguments: arguments)
        guard exited, process.terminationStatus == 0 else { return nil }

        // The child has exited, so with CLOEXEC pipes EOF is already in the
        // buffer; the deadline only bounds descriptors leaked outside our
        // control.
        let drainDeadline = Date().addingTimeInterval(Self.probeTimeoutSeconds)
        let stdout =
            String(
                data: boundedReadToEOF(
                    fromDescriptor: output.fileHandleForReading.fileDescriptor,
                    deadline: drainDeadline),
                encoding: .utf8) ?? ""
        let stderr =
            String(
                data: boundedReadToEOF(
                    fromDescriptor: error.fileHandleForReading.fileDescriptor,
                    deadline: drainDeadline),
                encoding: .utf8) ?? ""
        let combined = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    private func runStatus(command: String, arguments: [String]) async -> Int32? {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        setCloseOnExec(output)
        setCloseOnExec(error)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return nil
        }
        let exited = await waitWithTimeout(process: process, command: command, arguments: arguments)
        guard exited else { return nil }
        return process.terminationStatus
    }

    /// Polls `process.isRunning` cooperatively for up to `probeTimeoutSeconds`,
    /// then kills the process if it hasn't exited. Returns true if the process
    /// finished on its own, false if it had to be terminated.
    private func waitWithTimeout(process: Process, command: String, arguments: [String]) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.probeTimeoutSeconds)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                try? await Task.sleep(nanoseconds: 200_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                _ = try? await Task.sleep(nanoseconds: 100_000_000)
                writeStructuredRunnerLog(
                    event: "local_execution_error",
                    fields: [
                        "error_type": "capability_detection_timeout",
                        "error_message_summary": "\(command) \(arguments.joined(separator: " "))",
                        "timeout_seconds": Self.probeTimeoutSeconds,
                    ])
                return false
            }
            try? await Task.sleep(nanoseconds: 25_000_000)  // 25 ms
        }
        return true
    }

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
    /// nothing for want of a digit. Every one of the six banners is pinned in
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
