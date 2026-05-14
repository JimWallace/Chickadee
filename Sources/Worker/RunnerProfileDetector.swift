import Core
import Foundation

struct RunnerProfileDetector {
    let discoveryEnabled: Bool

    /// Wall-clock cap on any single capability probe. Keeps a broken `python3`
    /// wrapper, an NFS stall, or a hung `which` from blocking runner startup
    /// indefinitely.
    static let probeTimeoutSeconds: Double = 5.0

    init(discoveryEnabled: Bool) {
        self.discoveryEnabled = discoveryEnabled
    }

    func detect() async -> RunnerCapabilityProfile? {
        guard discoveryEnabled else { return nil }

        // Run independent probes concurrently — capability detection used to
        // serialize ~5 subprocesses at every cold start.
        async let pythonVersionOpt = detectVersion(command: "python3", arguments: ["--version"])
        async let rVersionOpt      = detectVersion(command: "R", arguments: ["--version"])
        async let swiftVersionOpt  = detectVersion(command: "swift", arguments: ["--version"])
        async let bashExists       = commandExists("bash")
        async let zshExists        = commandExists("zsh")

        var languageVersions: [LanguageVersion] = []
        var capabilities: Set<RunnerCapability> = []

        if let pythonVersion = await pythonVersionOpt {
            languageVersions.append(LanguageVersion(language: "python", version: pythonVersion))
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
        if let rVersion = await rVersionOpt {
            languageVersions.append(LanguageVersion(language: "r", version: rVersion))
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            writeStructuredRunnerLog(event: "local_execution_error", fields: [
                "error_type": "capability_detection_failed",
                "error_message_summary": "\(command): \(error.localizedDescription)",
            ])
            return nil
        }

        let exited = await waitWithTimeout(process: process, command: command, arguments: arguments)
        guard exited, process.terminationStatus == 0 else { return nil }

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    private func runStatus(command: String, arguments: [String]) async -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
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
                writeStructuredRunnerLog(event: "local_execution_error", fields: [
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
        for token in raw.split(whereSeparator: \.isWhitespace) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()"))
            let numericPrefix = cleaned.prefix { $0.isNumber || $0 == "." }
            if !numericPrefix.isEmpty, numericPrefix.contains(".") {
                return String(numericPrefix)
            }
        }
        return nil
    }
}
