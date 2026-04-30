import Core
import Foundation

struct RunnerProfileDetector {
    let discoveryEnabled: Bool

    init(discoveryEnabled: Bool) {
        self.discoveryEnabled = discoveryEnabled
    }

    func detect() -> RunnerCapabilityProfile? {
        guard discoveryEnabled else { return nil }

        var languageVersions: [LanguageVersion] = []
        var capabilities: Set<RunnerCapability> = []

        if let pythonVersion = detectVersion(command: "python3", arguments: ["--version"]) {
            languageVersions.append(LanguageVersion(language: "python", version: pythonVersion))
            for capability in ["numpy", "pandas", "scipy", "matplotlib"] where pythonImportAvailable(module: capability) {
                capabilities.insert(RunnerCapability(name: capability))
            }
        }

        if let rVersion = detectVersion(command: "R", arguments: ["--version"]) {
            languageVersions.append(LanguageVersion(language: "r", version: rVersion))
        }

        if let swiftVersion = detectVersion(command: "swift", arguments: ["--version"]) {
            languageVersions.append(LanguageVersion(language: "swift", version: swiftVersion))
        }

        if commandExists("bash") {
            capabilities.insert(RunnerCapability(name: "shell-bash"))
        }
        if commandExists("zsh") {
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

    private func detectVersion(command: String, arguments: [String]) -> String? {
        guard let output = run(command: command, arguments: arguments) else { return nil }
        return firstNumericVersion(in: output)
    }

    private func pythonImportAvailable(module: String) -> Bool {
        runStatus(
            command: "python3",
            arguments: ["-c", "import \(module)"]
        ) == 0
    }

    private func commandExists(_ command: String) -> Bool {
        runStatus(command: "which", arguments: [command]) == 0
    }

    private func run(command: String, arguments: [String]) -> String? {
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

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    private func runStatus(command: String, arguments: [String]) -> Int32? {
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
        process.waitUntilExit()
        return process.terminationStatus
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
