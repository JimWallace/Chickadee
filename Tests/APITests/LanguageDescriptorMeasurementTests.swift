// Tests/APITests/LanguageDescriptorMeasurementTests.swift
//
// Two `LanguageDescriptor` fields state facts about a real interpreter. This
// asks the interpreter.
//
// Most of the descriptor is NORMATIVE — it decides something, and the code
// obeys. `inputsFileName` is whatever it says because everything reads it from
// there. These two are different: they are claims ABOUT the outside world, true
// or false independently of what the descriptor says, and until now nothing
// checked them. Both have already been wrong:
//
//   * `interpreterProbe.versionArguments` was hardcoded `--version`, which
//     **fails on lua** — it prints usage and exits 1. So no runner ever
//     advertised Lua, and an assignment requiring it matched nothing and queued
//     forever. The symptom was an assignment that never graded, with no error
//     anywhere.
//   * `workingDirectoryIsOnDefaultSearchPath` predicted Octave needed
//     `OCTAVE_PATH` because its cwd was off the default path. Measuring showed
//     `.` is the FIRST entry of Octave's load path. The descriptor's own
//     comment records that as "an armchair answer" — this is the measurement it
//     asks for, run every time instead of once.
//
// HOW THE SECOND ONE IS MEASURED. Not by parsing a path listing, which would be
// a second armchair answer in a different notation, but by the observable
// consequence the field exists to predict: put a module in one directory and
// the script that loads it BY NAME in another, run the script with the working
// directory set to the module's and the search-path variable removed from the
// environment, and see whether the language finds it. That is exactly the
// question the runner asks when it decides whether to set one.
//
// The two-directory separation is the whole measurement, and collapsing it
// disagreed with a correct descriptor twice while this file was being written.
// Put the module beside the script and every language looks alike, because a
// language that puts the SCRIPT's directory on its path finds it too — which is
// a different fact. Python is the case that distinguishes them: it never puts
// the working directory on `sys.path`, which is why its answer is `false` and
// why the personalization driver, whose script and helpers live in different
// directories, needs `PYTHONPATH`.
//
// Both disagreements this test produced turned out to be the test's fault, not
// the descriptor's — the other being a C-style ternary that Octave does not
// have, whose parse error presented as "module not found". Neither descriptor
// value was changed. Recorded because the tempting move on a red measurement is
// to trust the measurement.
//
// Every assertion skips silently when its interpreter is absent — a laptop
// without Octave is not a defect — so this only fully means anything in CI,
// which is where the language matrix already relies on the image.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(3))) struct LanguageDescriptorMeasurementTests {

    /// Runs `command` with `arguments` in `directory`, with the named
    /// environment variables removed, and returns its status and output.
    private static func run(
        _ command: String, _ arguments: [String],
        in directory: URL? = nil, removingEnvironment: [String] = []
    ) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        for key in removingEnvironment { environment.removeValue(forKey: key) }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func isPresent(_ language: AssignmentLanguage) -> Bool {
        let probe = language.descriptor.interpreterProbe
        return run(probe.command, probe.versionArguments)?.status == 0
    }

    // MARK: - interpreterProbe

    /// The probe must EXIT 0 and say something. Capability detection reads both:
    /// a non-zero status means the runner never advertises the language, and an
    /// empty version string means it advertises one no `minimumVersion`
    /// requirement can match.
    ///
    /// Note this cannot be written as "skip if absent" the usual way, because
    /// the probe IS the availability test. Absence is established by running the
    /// command at all — if `/usr/bin/env` cannot find it, there is nothing to
    /// assert; if it runs, its contract applies.
    @Test(arguments: AssignmentLanguage.allCases)
    func theInterpreterProbeSucceedsWhereTheToolIsInstalled(
        _ language: AssignmentLanguage
    ) throws {
        let probe = language.descriptor.interpreterProbe
        guard let result = Self.run(probe.command, probe.versionArguments) else { return }
        // A shell reports 127 for "command not found"; that is absence, not a
        // broken probe.
        guard result.status != 127 else { return }
        #expect(
            result.status == 0,
            """
            \(language): `\(probe.command) \(probe.versionArguments.joined(separator: " "))` \
            exited \(result.status). A probe that does not exit 0 makes the language \
            undetectable — no runner advertises it and an assignment requiring it queues \
            forever, with no error anywhere. This is exactly how `--version` on lua failed.
            Output: \(result.output.prefix(200))
            """)
        #expect(
            !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(language): the probe printed nothing, so there is no version to advertise")
    }

    // MARK: - workingDirectoryIsOnDefaultSearchPath

    /// A module in the working directory, and the source that loads it by name,
    /// for the languages where the question means anything.
    ///
    /// EXHAUSTIVE ON PURPOSE. A seventh language does not compile until it says
    /// how the question is asked of it — or says it cannot be asked, which is a
    /// legitimate answer for a language that reads files rather than resolving
    /// names.
    private struct SearchPathProbe {
        let moduleFileName: String
        let moduleSource: String
        /// Source that loads the module by NAME and exits 0 only if it worked.
        let runnerSource: String
        /// Its filename. Written into a SEPARATE directory from the module and
        /// run by absolute path, with the working directory set to the module's.
        ///
        /// The separation IS the measurement, and getting it wrong disagreed
        /// with a correct descriptor twice while this test was being written.
        /// The field asks about the WORKING directory, which is not the same
        /// place as the script's directory — Python puts the SCRIPT's directory
        /// on `sys.path` and never the working directory, which is exactly why
        /// its answer is `false` and why the personalization driver, whose
        /// script and helpers sit in different directories, needs `PYTHONPATH`.
        /// Put the module beside the script and every language looks alike;
        /// separate them and they stop.
        ///
        /// A file, not `-c` / `--eval`, for the same reason: those flags put
        /// the working directory on the path explicitly, which answers a
        /// question the runner never asks.
        let runnerFileName: String
    }

    private static func searchPathProbe(for language: AssignmentLanguage) -> SearchPathProbe? {
        switch language {
        case .python:
            return SearchPathProbe(
                moduleFileName: "ck_probe_module.py",
                moduleSource: "VALUE = 41\n",
                runnerSource: "import sys\nimport ck_probe_module\n"
                    + "sys.exit(0 if ck_probe_module.VALUE == 41 else 1)\n",
                runnerFileName: "ck_probe_runner.py")
        case .lua:
            return SearchPathProbe(
                moduleFileName: "ck_probe_module.lua",
                moduleSource: "return 41\n",
                runnerSource: "os.exit(require('ck_probe_module') == 41 and 0 or 1)\n",
                runnerFileName: "ck_probe_runner.lua")
        case .octave:
            // No C-style ternary in Octave. An `a ? b : c` here was a parse
            // error that presented as "module not found" and disagreed with a
            // descriptor that is right — measuring the wrong thing looks
            // exactly like measuring the right thing and disagreeing.
            return SearchPathProbe(
                moduleFileName: "ck_probe_module.m",
                moduleSource: "function v = ck_probe_module()\n  v = 41;\nend\n",
                runnerSource: "v = ck_probe_module();\nif v == 41\n  exit(0);\nelse\n  exit(1);\nend\n",
                runnerFileName: "ck_probe_runner.m")
        // R reads files (`source()`), so there is no name to resolve and no
        // search-path variable to set — the field is vacuously true and there
        // is nothing to measure. Racket resolves a module by PATH in
        // `dynamic-require`, which is likewise a file read. C++ resolves at
        // compile time via `-I`, not at run time at all.
        case .java:
            // Java's probe command is `javac`, so what runs here is a COMPILE
            // rather than an execution — and that is the honest measurement,
            // because javac's implicit source path and the JVM's class path are
            // the same list: both default to `.` and both are REPLACED (not
            // extended) by CLASSPATH. Compiling a runner that names the module
            // therefore answers exactly the question the field asks — can this
            // language find a file sitting in the working directory by name,
            // with no variable set?
            //
            // The `VALUE == 41` check is deliberately not load-bearing: javac
            // exits 0 on a successful compile whatever the program would do.
            // Findability is the property; the comparison just keeps the module
            // referenced so the compiler has to resolve it.
            //
            // Class names are capitalised because Java requires a public class
            // to live in a file of its own name, and the file names here are
            // what the module lookup is searching for.
            return SearchPathProbe(
                moduleFileName: "CkProbeModule.java",
                moduleSource: "public class CkProbeModule { public static final int VALUE = 41; }\n",
                runnerSource:
                    "public class CkProbeRunner {\n"
                    + "    public static void main(String[] a) {\n"
                    + "        System.exit(CkProbeModule.VALUE == 41 ? 0 : 1);\n"
                    + "    }\n}\n",
                runnerFileName: "CkProbeRunner.java")
        case .r, .racket, .cpp:
            return nil
        }
    }

    /// The claim, measured: with the language's search-path variable removed
    /// from the environment, can the interpreter load a module sitting in the
    /// working directory by name?
    ///
    /// `true` means the runner must NOT set the variable — and setting one that
    /// is not needed is not harmless: assigning `LUA_PATH` REPLACES the default
    /// path unless it contains `;;`, which would break the very lookup it was
    /// meant to enable.
    @Test(arguments: AssignmentLanguage.allCases)
    func theWorkingDirectoryClaimMatchesTheInterpreter(
        _ language: AssignmentLanguage
    ) throws {
        guard let probe = Self.searchPathProbe(for: language) else { return }
        guard Self.isPresent(language) else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-searchpath-\(UUID().uuidString)")
        // Two directories, deliberately. `work` is the working directory the
        // module sits in; `driver` holds the script, so a language that puts
        // the SCRIPT's directory on its path (Python) does not thereby find the
        // module and look like a language that puts the WORKING directory
        // there (Lua, Octave).
        let directory = root.appendingPathComponent("work")
        let driverDirectory = root.appendingPathComponent("driver")
        for dir in [directory, driverDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try probe.moduleSource.write(
            to: directory.appendingPathComponent(probe.moduleFileName),
            atomically: true, encoding: .utf8)
        try probe.runnerSource.write(
            to: driverDirectory.appendingPathComponent(probe.runnerFileName),
            atomically: true, encoding: .utf8)

        // Remove whatever variable this language's resolution names, so an
        // inherited one on the developer's machine cannot make an off-path
        // language look on-path.
        var scrubbed: [String] = []
        if case .byName(let variable, _) = language.descriptor.moduleResolution, let variable {
            scrubbed.append(variable)
        }

        let interpreter = language.descriptor.interpreterProbe.command
        let result = try #require(
            Self.run(
                interpreter,
                [driverDirectory.appendingPathComponent(probe.runnerFileName).path],
                in: directory, removingEnvironment: scrubbed),
            "\(language): could not run \(interpreter)")

        let found = result.status == 0
        #expect(
            found == language.descriptor.workingDirectoryIsOnDefaultSearchPath,
            """
            \(language): the descriptor says the working directory \
            \(language.descriptor.workingDirectoryIsOnDefaultSearchPath ? "IS" : "is NOT") on the \
            default search path, and \(interpreter) \(found ? "found" : "did not find") a module \
            there with \(scrubbed.isEmpty ? "no search-path variable to remove" : scrubbed.joined())\
             removed.

            This field decides whether the runner sets a search-path variable. Getting it wrong in \
            one direction leaves a submission unable to import its own helper; in the other it sets \
            a variable that REPLACES the default path (LUA_PATH without `;;`), breaking the lookup \
            it was meant to enable.
            Interpreter output: \(result.output.prefix(300))
            """)
    }

    /// The languages the measurement skips must skip for a stated reason, not
    /// because someone forgot them. `fileRead` languages have no name to
    /// resolve; C++ resolves at compile time.
    @Test func everyUnmeasuredLanguageResolvesWithoutASearchPath() {
        for language in AssignmentLanguage.allCases where Self.searchPathProbe(for: language) == nil {
            switch language.descriptor.moduleResolution {
            case .fileRead:
                continue  // nothing is name-addressable; the field is vacuous
            case .byName(let variable, _):
                #expect(
                    variable == nil,
                    """
                    \(language) resolves modules by name against \(variable ?? "-") but has no \
                    search-path probe, so its workingDirectoryIsOnDefaultSearchPath claim is \
                    unmeasured. Add one to `searchPathProbe(for:)`.
                    """)
            }
        }
    }
}
