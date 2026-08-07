// Tests/APITests/OctavePersonalizationDriverTests.swift
//
// The Octave expression driver, executed rather than inspected — the Octave
// twin of LuaPersonalizationDriverTests, guarding the same two wrong-marks
// properties:
//
// 1. THE DRIVER'S OUTPUT IS OCTAVE SOURCE, not a display form. The server
//    writes it verbatim into `_ck_inputs.m`, so a value that renders as
//    something Octave cannot parse makes every per-student input silently read
//    as missing (the reader's `try` swallows the eval error and answers an
//    empty map).
//
// 2. THE SEED THE DRIVER BINDS MUST EQUAL THE SEED A GRADED SCRIPT READS.
//    `OctavePersonalizationRuntime.chickadeeSeedOctaveSource` and
//    `chickadee.seed()` in `test_runtime.m` are two copies of one Horner fold.
//    If they diverge, an instructor's preview shows one set of values and the
//    student's tests grade against another — with nothing failing anywhere.
//
// Skipped silently when `octave-cli` is absent, matching the conformance
// matrix; `octaveIsPresentInCI` is the did-not-skip proof.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct OctavePersonalizationDriverTests {

    static var octaveAvailable: Bool {
        OctavePatternFamilyExecutionTests.hasOctave
    }

    /// Runs `source` as an Octave script in a fresh directory, returning
    /// (exitCode, stdout, stderr). `extraFiles` are written beside it.
    static func runOctave(
        _ source: String,
        extraFiles: [String: String] = [:],
        seed: String? = nil
    ) throws -> (Int32, String, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-octdriver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, contents) in extraFiles {
            try contents.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let script = dir.appendingPathComponent("driver.m")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["octave-cli", script.path]
        process.currentDirectoryURL = dir
        if let seed {
            var env = ProcessInfo.processInfo.environment
            env["CHICKADEE_ASSIGNMENT_SEED"] = seed
            process.environment = env
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    @Test func theDriverEvaluatesExpressionsAndEmitsOctaveLiterals() throws {
        guard Self.octaveAvailable else { return }

        let source = PersonalizationEvaluator.renderOctaveDriverScript(
            staticVariables: [FamilyVariable(name: "base", value: .int(10))],
            expressions: [
                PersonalizationExpression(name: "doubled", expression: "base * 2"),
                // References an earlier expression, which is what forces the
                // driver to bind each result in the shared workspace.
                PersonalizationExpression(name: "quadrupled", expression: "doubled * 2"),
                PersonalizationExpression(name: "label", expression: "[\"row \" num2str(doubled)]"),
                PersonalizationExpression(name: "values", expression: "[1, 2.5, 4]"),
            ]
        )
        let (code, stdout, stderr) = try Self.runOctave(
            source, seed: String(repeating: "a", count: 64))
        #expect(code == 0, "driver failed: \(stderr)")

        let lastLine = stdout.split(separator: "\n").last.map(String.init) ?? ""
        let decoded =
            (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: String]
        let values = try #require(decoded, "driver did not emit a JSON map; stdout was: \(stdout)")

        #expect(values["doubled"] == "20")
        #expect(values["quadrupled"] == "40")
        #expect(values["label"] == "\"row 20\"")
        // Emitted as Octave source, so the vector keeps its brackets and the
        // float its decimal point — this is what lands in `_ck_inputs.m`.
        #expect(values["values"] == "[1, 2.5, 4]")
    }

    /// The emitted literals must be *parseable Octave*, not merely plausible.
    @Test func everyEmittedValueParsesBackAsOctave() throws {
        guard Self.octaveAvailable else { return }

        let source = PersonalizationEvaluator.renderOctaveDriverScript(
            staticVariables: [],
            expressions: [
                PersonalizationExpression(name: "n", expression: "7"),
                PersonalizationExpression(name: "f", expression: "1/3"),
                PersonalizationExpression(name: "s", expression: "\"he said \\\"hi\\\"\""),
                PersonalizationExpression(name: "t", expression: "{1, [2, 3], \"x\"}"),
                PersonalizationExpression(name: "b", expression: "true"),
            ]
        )
        let (code, stdout, stderr) = try Self.runOctave(source, seed: "ff")
        #expect(code == 0, "driver failed: \(stderr)")
        let lastLine = stdout.split(separator: "\n").last.map(String.init) ?? ""
        let values = try #require(
            (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: String])

        for (name, literal) in values {
            let probe = "v = \(literal);\ndisp(\"parsed\");\n"
            let (rc, _, err) = try Self.runOctave(probe)
            #expect(
                rc == 0, "the driver emitted unparseable Octave for `\(name)`: \(literal) — \(err)")
        }
    }

    /// One seed, two implementations — both run on the same env var and
    /// compared, across a realistic 64-hex seed and the edge cases.
    @Test func theDriverSeedEqualsTheGradingRuntimeSeed() throws {
        guard Self.octaveAvailable else { return }

        let runtime = try OctavePatternFamilyExecutionTests.canonicalRuntime()
        for seed in [String(repeating: "9f3c", count: 16), "", "ff", "0"] {
            let driverSource = """
                1;
                \(OctavePersonalizationRuntime.chickadeeSeedOctaveSource)
                printf("%d\\n", chickadee_seed());
                """
            let (dcode, dout, derr) = try Self.runOctave(driverSource, seed: seed)
            #expect(dcode == 0, "driver seed failed: \(derr)")

            let runtimeSource = """
                chickadee = test_runtime();
                printf("%d\\n", chickadee.seed());
                """
            let (rcode, rout, rerr) = try Self.runOctave(
                runtimeSource, extraFiles: ["test_runtime.m": runtime], seed: seed)
            #expect(rcode == 0, "runtime seed failed: \(rerr)")

            let driverSeed = dout.trimmingCharacters(in: .whitespacesAndNewlines)
            let runtimeSeed = rout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                driverSeed == runtimeSeed,
                """
                For CHICKADEE_ASSIGNMENT_SEED=\(seed.isEmpty ? "(unset)" : seed) the driver bound \
                \(driverSeed) but a graded script reads \(runtimeSeed). \
                `OctavePersonalizationRuntime.chickadeeSeedOctaveSource` and `chickadee.seed()` in \
                Tools/runner-support/test_runtime.m have diverged — an instructor's preview and \
                the student's grade would use different numbers, with nothing failing.
                """)
        }
    }

    /// The seed must also match every other language's, so a student's seed is
    /// one number whatever the assignment's language. Asserted against the fold
    /// computed independently in Swift.
    @Test func theOctaveSeedMatchesTheDocumentedHornerFold() throws {
        guard Self.octaveAvailable else { return }

        let seed = "abc123"
        let source = """
            1;
            \(OctavePersonalizationRuntime.chickadeeSeedOctaveSource)
            printf("%d\\n", chickadee_seed());
            """
        let (code, out, err) = try Self.runOctave(source, seed: seed)
        #expect(code == 0, "driver failed: \(err)")

        var expected = 0
        for character in seed.lowercased() {
            guard let digit = character.hexDigitValue else { continue }
            expected = (expected * 16 + digit) % 2_147_483_647
        }
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == String(expected))
    }
}
