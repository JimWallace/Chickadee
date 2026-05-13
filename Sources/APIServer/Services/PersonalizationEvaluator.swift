// APIServer/Services/PersonalizationEvaluator.swift
//
// Slice 2 of #461 — server-side evaluation of `PersonalizationExpression`
// rows with `seed` bound to the per-(student, assignment) hex seed.
//
// Each evaluation spawns `python3` against a tiny generated driver
// script that binds `seed`, every static `globalVariables` + section
// variable as Python module-level names, then evaluates each
// expression in declared order so later expressions can reference
// earlier ones.  Values are emitted as `repr(value)` strings — drop-in
// Python literals that `NotebookSubstitution.apply` substitutes into
// `{{name}}` placeholders.
//
// Trust model: instructor-authored Python on the instructor's own
// server.  Same risk profile as the validation-submission path that
// already executes instructor solution notebooks server-side.
// Sandboxed-exec parity with the worker (`sandbox-exec` /  `unshare`)
// is a future hardening; called out in the docs.

import Foundation
import Core

enum PersonalizationEvaluatorError: Error {
    case driverWriteFailed
    case spawnFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut
    case malformedOutput(stdout: String)
    case missingName(name: String, stdout: String)
}

enum PersonalizationEvaluator {

    /// Timeout (seconds) for a single evaluation subprocess.  Slice 2
    /// caps at 5 s — instructor expressions should be near-instant;
    /// anything slower is almost certainly a bug.
    static let defaultTimeoutSeconds: Int = 5

    /// Evaluates each `expressions` entry with `seed` and all listed
    /// static variables in scope.  Returns the rendered Python literal
    /// per expression name, suitable for dropping into a
    /// `NotebookSubstitution.apply` substitutions map.
    ///
    /// - `seedHex`: 64-char lowercase hex (the value persisted by
    ///   `AssignmentSeedStore`).  Sent to the subprocess as
    ///   `CHICKADEE_ASSIGNMENT_SEED` so the driver re-uses Phase 1's
    ///   wire contract.
    /// - `staticVariables`: every literal name in scope (globals +
    ///   section vars combined).  Order matters when names collide —
    ///   later entries win, matching the notebook substitution map's
    ///   "section overrides global" precedence.
    /// - `expressions`: evaluated in declared order, each seeing
    ///   `seed`, every entry in `staticVariables`, and every prior
    ///   expression's value as a Python global.
    static func evaluate(
        seedHex: String,
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws -> [String: String] {
        guard !expressions.isEmpty else { return [:] }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("chickadee_personalize_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let driverSource = renderDriverScript(
            staticVariables: staticVariables,
            expressions: expressions
        )
        let driverURL = tempDir.appendingPathComponent("personalize_driver.py")
        do {
            try driverSource.write(to: driverURL, atomically: true, encoding: .utf8)
        } catch {
            throw PersonalizationEvaluatorError.driverWriteFailed
        }

        let stdout: String
        let stderr: String
        let exitCode: Int32
        do {
            (stdout, stderr, exitCode) = try await spawnAndCapture(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", driverURL.path],
                cwd: tempDir,
                env: ["CHICKADEE_ASSIGNMENT_SEED": seedHex],
                timeoutSeconds: timeoutSeconds
            )
        } catch PersonalizationEvaluatorError.timedOut {
            throw PersonalizationEvaluatorError.timedOut
        } catch {
            throw PersonalizationEvaluatorError.spawnFailed(String(describing: error))
        }

        if exitCode != 0 {
            throw PersonalizationEvaluatorError.nonZeroExit(code: exitCode, stderr: stderr)
        }

        // Parse the last non-empty line of stdout as JSON (mirrors the
        // runner's "last-line JSON" contract — instructor `print` calls
        // earlier in the driver don't break parsing).
        let lastLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        guard let data = lastLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            throw PersonalizationEvaluatorError.malformedOutput(stdout: stdout)
        }

        // Defensive: every declared expression should have a value.
        for expr in expressions where obj[expr.name] == nil {
            throw PersonalizationEvaluatorError.missingName(name: expr.name, stdout: stdout)
        }
        return obj
    }

    // MARK: - Internals

    static func renderDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression]
    ) -> String {
        var lines: [String] = [
            "# Auto-generated personalization driver.  Do not edit.",
            "import json, os",
            "",
            "seed = int(os.environ['CHICKADEE_ASSIGNMENT_SEED'], 16)",
            ""
        ]
        if !staticVariables.isEmpty {
            lines.append("# Static globals + section variables (in scope for expressions).")
            for v in staticVariables {
                lines.append("\(v.name) = \(v.value.pythonLiteral)")
            }
            lines.append("")
        }
        lines.append("# Per-student expressions, evaluated in declared order.")
        for e in expressions {
            lines.append("\(e.name) = (\(e.expression))")
        }
        lines.append("")
        lines.append("# Emit one `repr(value)` per declared expression as a JSON map.")
        lines.append("_out = {}")
        for e in expressions {
            lines.append("_out[\(stringLiteral(e.name))] = repr(\(e.name))")
        }
        lines.append("print(json.dumps(_out))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Emits a Python-safe single-quoted string literal for an
    /// identifier-shape name.  Identifiers can't contain special chars,
    /// so quoting `'name'` directly is safe; no escaping needed.
    private static func stringLiteral(_ s: String) -> String {
        "'\(s)'"
    }

    /// Spawns a subprocess with the given env (merged with the parent's
    /// env), captures stdout/stderr, kills + reports timeout if it
    /// outruns `timeoutSeconds`.
    private static func spawnAndCapture(
        executableURL: URL,
        arguments: [String],
        cwd: URL,
        env: [String: String],
        timeoutSeconds: Int
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.currentDirectoryURL = cwd
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { mergedEnv[k] = v }
        proc.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        do {
            try proc.run()
        } catch {
            throw PersonalizationEvaluatorError.spawnFailed(String(describing: error))
        }

        let timeoutTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            if proc.isRunning {
                proc.terminate()
                return true
            }
            return false
        }
        proc.waitUntilExit()
        let didTimeOut = await timeoutTask.value

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if didTimeOut {
            throw PersonalizationEvaluatorError.timedOut
        }
        return (stdout, stderr, proc.terminationStatus)
    }
}
