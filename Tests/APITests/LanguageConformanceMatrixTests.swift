// Tests/APITests/LanguageConformanceMatrixTests.swift
//
// The language conformance matrix: what "supported" MEANS, asserted for every
// `AssignmentLanguage` rather than for whichever ones someone remembered.
//
// WHY THIS EXISTS. Before it, the suite had exactly one test parameterised over
// language, and it read `arguments: [AssignmentLanguage.python, .r]` — a
// hand-listed pair, not `allCases`. Adding a third case would have left it
// silently testing two languages and passing. That is the same "enumerated
// rather than discovered, fails open" shape this codebase has already been
// bitten by twice, both recorded in docs/adding-a-xeus-kernel.md: the
// `chickadee-*` glob in build-jupyterlite.sh (a kernel with no module index)
// and `expected_language` in check-xeus-vendored.sh (a kernel with no vendoring
// guard). Neither errored; you simply got something nothing checked.
//
// R's support is otherwise seven hand-written R-twin test files. A third
// language would have been a seventh parallel copy, which is why the third
// language was costing nearly as much as the second: nothing generalised.
//
// HOW IT AVOIDS BEING THE SAME BUG. Everything here iterates `allCases`, and
// the per-language glue the matrix itself needs lives in ONE exhaustive switch
// (`adapter(for:)`). Adding a case to `AssignmentLanguage` fails to compile
// until that arm exists, and then fails the suite until the behaviour does.
// The compiler produces the worklist; this produces the definition of done.
//
// WHAT IT DELIBERATELY CANNOT DO. Assertions that need a real interpreter are
// skipped when it is absent, following the existing `hasRscript` pattern —
// silently, because a missing R on a contributor's laptop is not a defect. The
// STRUCTURAL half never skips, so a language can never be entirely unexamined.
//
// The executed half therefore only means anything where every interpreter is
// present, which is CI. That makes the CI image a load-bearing part of this
// matrix and a silent one: a language missing from it does not go red, it
// stops being executed. So both images are asserted from `allCases` rather
// than described here — `theRunnerImageProvidesEveryInterpreter` for the
// production Dockerfile, `theCIImageAndItsProbeProvideEveryInterpreter` for the
// swift-ci image and the swift-tests.yml probe that falls back to installing
// it. Neither can drift; this comment deliberately names no package list,
// because a list in prose is the thing that was wrong.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(5))) struct LanguageConformanceMatrixTests {

    // MARK: - Per-language glue, in one compiler-forced place

    /// The language-specific fragments the matrix needs in order to run
    /// anything. Everything else in this file is generic over `allCases`.
    struct Adapter {
        /// The command the runner spawns via `/usr/bin/env` for this language.
        let interpreter: String
        /// The flag that means "the next argument is source, not a filename".
        /// It is NOT the same everywhere — python3 takes `-c` and Rscript takes
        /// `-e` — and this matrix's first run failed on exactly that, which is
        /// a small demonstration of why the glue belongs in one forced place.
        let evalFlag: String
        /// Arguments that make the interpreter report its version and exit 0,
        /// used only to decide whether the executed half of the matrix can run.
        ///
        /// A field for the SAME reason `evalFlag` is one, learned the same way.
        /// This was hardcoded as `--version`, which python3 and Rscript accept
        /// and **lua does not** — `lua --version` prints a usage message and
        /// exits 1. So the availability probe answered "absent" on a machine
        /// with a perfectly good Lua, and every executed assertion skipped
        /// SILENTLY: the suite reported green having never parsed a line of
        /// generated Lua or read back a Lua inputs file.
        ///
        /// That is precisely the failure this file was written to prevent, one
        /// level up — the lesson from `evalFlag` was recorded but not
        /// generalised to its neighbour three lines away.
        let versionArguments: [String]
        /// The Debian package that provides it, as the Dockerfile installs it.
        let debianPackage: String
        /// The command whose presence proves this language's toolchain is
        /// installed, as CI's dependency probe spells it.
        ///
        /// NOT always `interpreter`, and C++ is why it is a field rather than a
        /// derivation: C++ is spawned through `sh`, which exists on every
        /// machine and would make the probe vacuously true. What actually has
        /// to be there is `g++`. It equals `debianPackage` for that one
        /// language, which is a coincidence — deriving it from either
        /// neighbour is the sort of "the other four agree, so" reasoning this
        /// file exists to stop.
        let toolchainProbeCommand: String
        /// Source that parses `path` WITHOUT executing it, exiting non-zero on
        /// a syntax error. A parse check, not a run: generated scripts expect a
        /// student submission and a runtime beside them.
        let parseOnlyProgram: (String) -> String
        /// Source that loads this language's inputs file from the working
        /// directory and prints the value bound to `key`.
        let readInputsProgram: (_ key: String) -> String
    }

    // swiftlint:disable function_body_length
    /// EXHAUSTIVE ON PURPOSE. A new `AssignmentLanguage` case does not compile
    /// until it supplies its glue here, which is what stops the matrix from
    /// quietly covering one fewer language than exists.
    ///
    /// Long by construction — a table of literals that grows ~25 lines per
    /// language — so `function_body_length` is disabled for it locally rather
    /// than raised for all of Tests/. Splitting it would put one language's
    /// glue somewhere other than beside its neighbours, and this file's whole
    /// premise is that they are readable side by side.
    static func adapter(for language: AssignmentLanguage) -> Adapter {
        switch language {
        case .java:
            // Java's generated "scripts" are POSIX shell wrappers like C++'s,
            // so the glue runs through `sh -c` on the same substrate the runner
            // uses, and the parse check is `sh -n` over the wrapper (the Java
            // inside is executed, not parsed, by the execution suite).
            //
            // The availability probe goes through sh TO **javac**, not `java`:
            // the compiler is the binary a JRE-only host lacks, and it is what
            // the descriptor probes for the same reason.
            //
            // Reading the inputs file compiles a two-line class against
            // `_ck_inputs.java`, which javac pulls in from the sourcepath
            // because its filename matches its class name. `-cp .` is explicit
            // rather than relied upon: it is on the default classpath only
            // while CLASSPATH is unset, and this runs in whatever environment
            // CI has.
            return Adapter(
                interpreter: "sh",
                evalFlag: "-c",
                versionArguments: ["-c", "javac --version"],
                debianPackage: "default-jdk",
                toolchainProbeCommand: "javac",
                parseOnlyProgram: { path in
                    "sh -n '\(path)'"
                },
                readInputsProgram: { key in
                    """
                    cat > CkReadInputs.java <<'CK_READ_EOF'
                    public class CkReadInputs {
                        public static void main(String[] a) {
                            System.out.println(_ck_inputs.\(key));
                        }
                    }
                    CK_READ_EOF
                    javac -cp . -d . CkReadInputs.java && java -cp . CkReadInputs
                    """
                }
            )
        case .cpp:
            // C++ has no interpreter, and its generated "scripts" are POSIX
            // shell wrappers carrying the C++ source in a heredoc — so the
            // glue runs through `sh -c`, the same substrate the runner uses.
            // The availability probe goes through sh TO g++ (`sh --version`
            // is not portable, and g++ is the real dependency); the parse
            // check is `sh -n` over the wrapper (the C++ inside is executed,
            // not parsed, by the execution suites); reading the inputs file
            // compiles a two-line program against `_ck_inputs.hpp`, which
            // carries its own includes.
            return Adapter(
                interpreter: "sh",
                evalFlag: "-c",
                versionArguments: ["-c", "g++ --version"],
                debianPackage: "g++",
                toolchainProbeCommand: "g++",
                parseOnlyProgram: { path in
                    "sh -n '\(path)'"
                },
                readInputsProgram: { key in
                    """
                    cat > .ck_read_inputs.cpp <<'CK_READ_EOF'
                    #include <iostream>
                    #include "_ck_inputs.hpp"
                    int main() { std::cout << ck_inputs::\(key) << "\\n"; }
                    CK_READ_EOF
                    g++ -std=c++20 -O0 .ck_read_inputs.cpp -o .ck_read_inputs && ./.ck_read_inputs
                    """
                }
            )
        case .racket:
            // Racket parses with `raco make`? No — that COMPILES, and would
            // need the submission present. `racket -e` with `read` over the
            // file's port parses it and nothing more, which is what this field
            // asks for. The `#lang` line is part of the syntax, so the read
            // goes through `read-language` first.
            return Adapter(
                interpreter: "racket",
                evalFlag: "-e",
                versionArguments: ["--version"],
                debianPackage: "racket",
                toolchainProbeCommand: "racket",
                parseOnlyProgram: { path in
                    """
                    (let ([in (open-input-file \"\(path)\")])
                      (read-language in)
                      (let loop () (unless (eof-object? (read in)) (loop))))
                    """
                },
                readInputsProgram: { key in
                    """
                    (displayln (hash-ref (dynamic-require \"_ck_inputs.rkt\" 'ck-inputs) \"\(key)\"))
                    """
                }
            )
        case .python:
            return Adapter(
                interpreter: "python3",
                evalFlag: "-c",
                versionArguments: ["--version"],
                debianPackage: "python3",
                toolchainProbeCommand: "python3",
                parseOnlyProgram: { path in
                    "import ast,sys;ast.parse(open(\(pythonString(path))).read())"
                },
                readInputsProgram: { key in
                    "import _ck_inputs;print(_ck_inputs._ck[\(pythonString(key))])"
                }
            )
        case .r:
            return Adapter(
                interpreter: "Rscript",
                evalFlag: "-e",
                versionArguments: ["--version"],
                debianPackage: "r-base",
                toolchainProbeCommand: "Rscript",
                parseOnlyProgram: { path in "invisible(parse(\(rString(path))))" },
                readInputsProgram: { key in
                    // Mirrors chickadee_inputs(): source into a fresh env, read
                    // the binding it leaves behind.
                    """
                    env <- new.env(); sys.source("_ck_inputs.R", envir = env)
                    cat(get(".ck_inputs", envir = env)[[\(rString(key))]], "\\n")
                    """
                }
            )
        case .lua:
            return Adapter(
                interpreter: "lua",
                evalFlag: "-e",
                versionArguments: ["-v"],
                debianPackage: "lua5.4",
                toolchainProbeCommand: "lua",
                // `loadfile` compiles without running, which is exactly the
                // parse check wanted here — `dofile` would execute a script
                // that expects a submission and a runtime beside it.
                parseOnlyProgram: { path in "assert(loadfile(\(luaString(path))))" },
                readInputsProgram: { key in
                    // Mirrors chickadee.inputs(), INCLUDING the environment it
                    // supplies: the chunk is data, but that data may name
                    // `chickadee.NULL` for a JSON null inside a table, so the
                    // reader is what binds `chickadee`. A stub with just the
                    // sentinel is enough, and keeps this from depending on
                    // test_runtime.lua being copied into the scratch directory.
                    """
                    local env = setmetatable({ chickadee = { NULL = setmetatable({}, {}) } },
                                             { __index = _G })
                    local chunk = assert(loadfile("_ck_inputs.lua", "t", env))
                    local values = chunk()
                    assert(values[\(luaString(key))] ~= nil, "missing key")
                    print(tostring(values[\(luaString(key))]))
                    """
                }
            )
        case .octave:
            return Adapter(
                interpreter: "octave-cli",
                evalFlag: "--eval",
                versionArguments: ["--version"],
                debianPackage: "octave",
                toolchainProbeCommand: "octave-cli",
                // `__parse_file__` compiles a file without executing it —
                // verified: a script whose body prints does not print, a
                // mid-script `function` definition parses, and a syntax error
                // raises catchably. It is an internal builtin (the
                // double-underscore is Octave's own convention for those), so
                // if a future Octave drops it this arm fails LOUDLY here
                // rather than anything skipping.
                parseOnlyProgram: { path in
                    "try; __parse_file__(\(octString(path))); catch; exit(1); end"
                },
                readInputsProgram: { key in
                    // Mirrors chickadee.inputs(): evaluate the file's TEXT
                    // (never by its `_ck_inputs` script name) and zip the two
                    // parallel cell arrays.
                    """
                    ck_input_names = {}; ck_input_values = {};
                    eval(fileread("_ck_inputs.m"));
                    ck_found = false;
                    for ck_i = 1:numel(ck_input_names)
                        if strcmp(ck_input_names{ck_i}, \(octString(key)))
                            disp(ck_input_values{ck_i});
                            ck_found = true;
                        end
                    end
                    if !ck_found
                        exit(1);
                    end
                    """
                }
            )
        }
    }
    // swiftlint:enable function_body_length

    // MARK: - Structural invariants (never skipped)

    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageDeclaresAUsableScriptExtension(_ language: AssignmentLanguage) {
        #expect(!language.scriptExtensions.isEmpty)
        // A WRAPPER LANGUAGE breaks the round-trip DELIBERATELY: its generated
        // cases are POSIX shell wrappers (`.sh` — the compile step lives inside
        // the script), and `.sh` must keep carrying no language signal, or
        // every hand-written shell suite in every course would suddenly sniff
        // as that language. The wrapper never needs to classify back: the
        // runner runs it as the shell script it is.
        //
        // Asked as `generatesLanguagelessWrapper` rather than `== .cpp`, which
        // is what this read before Java became the second such language and
        // would have failed it for doing exactly the same correct thing.
        guard !language.generatesLanguagelessWrapper else {
            #expect(language.generatedScriptExtension == "sh")
            #expect(AssignmentLanguage(scriptExtension: "sh") == nil)
            return
        }
        // The generated extension must be one the language claims, or a
        // generated script would not classify back to the language that made it.
        #expect(language.scriptExtensions.contains(language.generatedScriptExtension.lowercased()))
        // …and round-trips through the extension->language lookup.
        #expect(AssignmentLanguage(scriptExtension: language.generatedScriptExtension) == language)
    }

    @Test func scriptExtensionsAreDisjointAcrossLanguages() {
        var seen: [String: AssignmentLanguage] = [:]
        for language in AssignmentLanguage.allCases {
            for ext in language.scriptExtensions {
                let existing = seen[ext]
                #expect(
                    existing == nil,
                    "\(ext) is claimed by both \(String(describing: existing)) and \(language)")
                seen[ext] = language
            }
        }
    }

    @Test func notebookKernelNamesAreDisjointAcrossLanguages() {
        // A kernel alias claimed by two languages makes `fromNotebookMetadata`
        // order-dependent, which is a silent mis-resolution rather than an error.
        var seen: [String: AssignmentLanguage] = [:]
        for language in AssignmentLanguage.allCases {
            for name in language.notebookKernelNames {
                #expect(seen[name] == nil, "kernel \(name) claimed twice")
                seen[name] = language
            }
        }
    }

    @Test(arguments: AssignmentLanguage.allCases)
    func theInputsFilenameMatchesTheLanguage(_ language: AssignmentLanguage) {
        let ext = (language.inputsFileName as NSString).pathExtension
        #expect(
            language.scriptExtensions.contains(ext.lowercased()),
            "\(language.inputsFileName) is not a \(language) source file")
    }

    @Test func inputsFilenamesAreDistinct() {
        let names = AssignmentLanguage.allCases.map(\.inputsFileName)
        #expect(Set(names).count == names.count, "two languages share an inputs filename")
    }

    @Test(arguments: AssignmentLanguage.allCases)
    func theKernelEnvironmentFileExists(_ language: AssignmentLanguage) {
        // The authoring rejection message names this file; a name that does not
        // exist sends an instructor to a path that is not there. A kernel-less
        // (upload-only) language names no file, so there is nothing to check —
        // expected for that language, hence the silent return.
        guard
            case .notebookKernel(let environmentFileName, _, _, _, _) = language.editorSupport
        else { return }
        let url = Self.repoRoot
            .appendingPathComponent("Tools/jupyterlite")
            .appendingPathComponent(environmentFileName)
        #expect(
            FileManager.default.fileExists(atPath: url.path),
            "\(environmentFileName) does not exist")
    }

    /// The defect that shipped with Lua: `.lua` classified to an `env lua`
    /// subprocess while the image installed only python3 and r-base, so every
    /// test exited 127 — and instructor validation, a NATIVE-worker job even for
    /// browser-graded assignments, could not pass either.
    @Test(arguments: AssignmentLanguage.allCases)
    func theRunnerImageProvidesEveryInterpreter(_ language: AssignmentLanguage) throws {
        let dockerfile = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Dockerfile"), encoding: .utf8)
        let package = Self.adapter(for: language).debianPackage
        #expect(
            dockerfile.contains(package),
            """
            The Dockerfile does not install \(package), which provides \
            \(Self.adapter(for: language).interpreter) for \(language) assignments. \
            Without it every test exits 127 and instructor validation cannot pass.
            """)
    }

    /// Non-comment lines only, so a guard cannot be satisfied by the prose that
    /// documents it.
    ///
    /// Not hypothetical tidiness: `.github/docker/ci-image/Dockerfile` names
    /// `r-base` in four comments and one install line, so a plain
    /// `contains("r-base")` would pass on a file that had stopped installing
    /// it. That is the "drift guard matched its own documentation" failure
    /// CLAUDE.md records having shipped twice, and this file's own new comments
    /// name every package — so writing the naive check here would have
    /// reproduced it a third time.
    static func codeLines(of text: String) -> [Substring] {
        text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
    }

    /// The CI image and its probe have to know every language too — and unlike
    /// the production image, this one fails SILENTLY. The executed assertions
    /// guard on interpreter availability and skip when it is absent, so a
    /// language missing from the swift-ci image (or from the probe that would
    /// otherwise apt-get it) leaves CI green having executed nothing in that
    /// language.
    ///
    /// R is why this exists. It was absent from both the probe and the fallback
    /// install list in swift-tests.yml for the entire time Lua, Octave and C++
    /// were being added to them, and nothing went red — invisible precisely
    /// because the only symptom is a test that does not run.
    @Test(arguments: AssignmentLanguage.allCases)
    func theCIImageAndItsProbeProvideEveryInterpreter(_ language: AssignmentLanguage) throws {
        let adapter = Self.adapter(for: language)

        let ciImage = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                ".github/docker/ci-image/Dockerfile"), encoding: .utf8)
        #expect(
            Self.codeLines(of: ciImage).contains { $0.contains(adapter.debianPackage) },
            """
            .github/docker/ci-image/Dockerfile does not install \
            \(adapter.debianPackage), so the swift-ci image has no \
            \(adapter.toolchainProbeCommand) and every \(language) execution-path \
            assertion skips. CI stays green having run none of them.
            """)

        let lines = try Self.codeLines(
            of: String(
                contentsOf: Self.repoRoot.appendingPathComponent(
                    ".github/workflows/swift-tests.yml"), encoding: .utf8))

        let probes = lines.filter { $0.contains("command -v ") }
        #expect(!probes.isEmpty, "swift-tests.yml has no dependency probe to check.")
        #expect(
            probes.allSatisfy { $0.contains("command -v \(adapter.toolchainProbeCommand) ") },
            """
            A dependency probe in swift-tests.yml does not check for \
            \(adapter.toolchainProbeCommand), so a stale swift-ci image missing \
            \(adapter.debianPackage) goes undetected, the apt-get fallback never runs, \
            and every \(language) execution-path assertion skips silently.
            """)

        // The fallback installs are the ones the PROBE guards — the `apt-get`
        // that runs when `command -v` says the image is stale. Identified by
        // that pairing rather than by `--no-install-recommends` alone, which
        // also matches unrelated installs: the browser-runner-tests job
        // installs lua5.4 and octave for the eval-snippet execution suites, on
        // a plain ubuntu runner with no swift-ci image and no reason to carry
        // r-base or racket. Matching it here demanded every language be
        // installed in a job that needs two of them.
        let installs = lines.filter {
            $0.contains("--no-install-recommends") && $0.contains("apt-get update")
        }
        #expect(!installs.isEmpty, "swift-tests.yml has no probe-guarded fallback install.")
        #expect(
            installs.allSatisfy { $0.contains(adapter.debianPackage) },
            """
            A fallback install in swift-tests.yml omits \(adapter.debianPackage), so a \
            stale swift-ci image leaves \(language) untested rather than failing.
            """)
    }

    /// Runner capability matching has to know the language exists, in BOTH
    /// directions, or it fails in one of two ways — and the second is worse:
    ///
    ///   * no requirement suggested for the assignment → its jobs go to any
    ///     runner, including one whose image has no interpreter, and every test
    ///     exits 127;
    ///   * no runner advertising the language → an assignment that DOES require
    ///     it matches nothing and queues forever.
    ///
    /// Lua had both. Neither is a compile error, because both lists were
    /// strings hand-written at the edges of a system whose types were already
    /// language-generic — `RunnerCompatibility.swift` needed no change at all,
    /// which is exactly why nothing pointed at the two that did.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageIsProbeableByARunner(_ language: AssignmentLanguage) {
        let probe = language.interpreterProbe
        #expect(!probe.command.isEmpty, "\(language) has no interpreter probe command")
        #expect(
            !probe.versionArguments.isEmpty,
            "\(language) has no version arguments — the probe cannot exit 0")
        // The advertised name is the token an assignment's required-languages
        // list is matched against, so the two halves must agree.
        #expect(language.capabilityName == language.rawValue)
    }

    /// Runs the real probe for whichever interpreters this machine has. The
    /// point is the ARGUMENTS: `lua --version` exits 1, and a hardcoded
    /// `--version` is what made Lua invisible to capability detection.
    @Test func everyLanguageProbeActuallyReportsAVersion() {
        for language in AssignmentLanguage.allCases {
            let probe = language.interpreterProbe
            let (code, _) = Self.run(probe.command, probe.versionArguments, in: Self.repoRoot)
            // The interpreter simply not being on this machine is not a defect,
            // and it is **exit 127** — `/usr/bin/env` reports command-not-found
            // that way, the same code the original Lua defect surfaced as. (-1
            // is this helper's own "could not even spawn env".) Everything else
            // must be a clean exit, which is what catches a probe whose
            // ARGUMENTS are wrong on an interpreter that is present: that case
            // exits 1, is indistinguishable from absence to the detector, and
            // silently costs the language its capability advertisement.
            guard code != -1, code != 127 else { continue }
            let invocation = "\(probe.command) \(probe.versionArguments.joined(separator: " "))"
            #expect(
                code == 0,
                """
                `\(invocation)` exited \(code). A runner probes exactly this to decide whether it \
                can grade \(language); a non-zero exit means it never advertises the language, and \
                an assignment requiring \(language) matches no runner at all.
                """)
        }
    }

    /// The did-not-skip proof (audit F2). Every language's execution tests
    /// guard on the interpreter being present and `return` silently when it is
    /// not — which is correct on a developer laptop and a silent hole in CI,
    /// where absence means a shipped grading path has zero coverage. `lua5.4`
    /// shipped in #1282 without being added to the CI image, so every native
    /// Lua test skipped while the suite reported green.
    ///
    /// This converts that into a hard failure: under `CI`, every interpreter
    /// MUST answer its probe. It runs only in CI (a laptop legitimately lacks
    /// R or Lua), so it never blocks local work — but it cannot be satisfied by
    /// skipping.
    @Test func noInterpreterIsSilentlyAbsentInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        for language in AssignmentLanguage.allCases {
            let probe = language.interpreterProbe
            let (code, _) = Self.run(probe.command, probe.versionArguments, in: Self.repoRoot)
            #expect(
                code == 0,
                """
                \(language)'s interpreter (`\(probe.command)`) is absent in CI, so its execution \
                tests skipped silently and its grading path has no coverage. Add it to \
                .github/docker/ci-image/Dockerfile and the per-job apt fallback in swift-tests.yml.
                """)
        }
    }

    // MARK: - Renderer coverage (never skipped)

    @Test(arguments: AssignmentLanguage.allCases)
    func everyPatternKindRendersInEveryLanguage(_ language: AssignmentLanguage) {
        for kind in PatternKind.allCases {
            let scripts = renderPatternFamily(
                GeneratedSourceFixtures.family(kind: kind, language: language), language: language)
            #expect(!scripts.isEmpty, "\(language)/\(kind) rendered no scripts")
            for script in scripts {
                #expect(
                    !script.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(language)/\(kind) rendered an empty script")
                #expect(
                    script.filename.hasSuffix(".\(language.generatedScriptExtension)"),
                    "\(language)/\(kind) generated \(script.filename), wrong extension")
            }
        }
    }

    @Test(arguments: AssignmentLanguage.allCases)
    func everyNotebookCheckKindRendersOrIsADeclaredException(_ language: AssignmentLanguage) {
        let exceptions = GeneratedSourceFixtures.notebookCheckKindExceptions[language] ?? []
        for kind in NotebookCheckKind.allCases where !exceptions.contains(kind) {
            let generated = renderNotebookCheck(GeneratedSourceFixtures.check(kind: kind), language: language)
            #expect(
                !generated.script.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(language)/\(kind) rendered an empty check — implement it or declare it")
        }
    }

    /// The student-facing wording must be the SAME in every language.
    ///
    /// It is currently hand-repeated: `"  expected: "` and `"  got:      "`
    /// each appear in fourteen files across both languages and both renderer
    /// families, with nothing tying them together. So a reworded Python failure
    /// silently diverges from the R one, and a student on an R lab reads
    /// different prose than a student on a Python lab for the same mistake.
    ///
    /// This pins them from the outside. It is also the guard that makes the
    /// planned extraction — hoisting this vocabulary into one place so a new
    /// language inherits it rather than retyping it — verifiable from both
    /// ends: the goldens prove the bytes did not move, and this proves the
    /// languages still agree.
    @Test func studentFacingWordingIsSharedAcrossLanguages() {
        // The field labels and phrases a generated failure message is built
        // from. Not every kind emits every one; the assertion is that whichever
        // ones a kind uses, it uses in EVERY language.
        let vocabulary = [
            "unexpected exception", "wrong value",
            "  input:    ", "  expected: ", "  got:      ", "Returned ",
        ]

        for kind in PatternKind.allCases {
            var perLanguage: [AssignmentLanguage: Set<String>] = [:]
            for language in AssignmentLanguage.allCases {
                let source = renderPatternFamily(
                    GeneratedSourceFixtures.family(kind: kind, language: language),
                    language: language
                )
                .map(\.source).joined(separator: "\n")
                perLanguage[language] = Set(vocabulary.filter { source.contains($0) })
            }
            // Python is the reference wording every other language is compared
            // against — named directly, since it is no longer "the default".
            guard let reference = perLanguage[.python] else { continue }
            for (language, used) in perLanguage where language != .python {
                #expect(
                    used == reference,
                    """
                    \(kind) uses different failure wording in \(language) than in Python. \
                    Only in Python: \(reference.subtracting(used).sorted()). \
                    Only in \(language): \(used.subtracting(reference).sorted()).
                    """)
            }
        }
    }

    // MARK: - Executed against the real interpreter (skipped when absent)

    /// The assertion that would have caught a whole class of renderer bug: a
    /// generated script that is not even syntactically valid in its own
    /// language. Cheap, and it needs no submission beside it.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyGeneratedScriptParsesInItsOwnLanguage(_ language: AssignmentLanguage) throws {
        let adapter = Self.adapter(for: language)
        guard Self.isAvailable(adapter) else { return }

        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for kind in PatternKind.allCases {
            let family = GeneratedSourceFixtures.family(kind: kind, language: language)
            // The cases AND the auto-generated existence guard. The guard was
            // missed at first, and the omission was invisible: it is produced by
            // `existenceGuard(for:)` rather than by `renderPatternFamily`, so
            // iterating the latter's result silently covered every generated
            // script except that one — in all three languages. It is the script
            // every other case in the family `dependsOn`, so a syntax error in
            // it fails the whole family at grade time.
            var scripts = renderPatternFamily(family, language: language)
            if let guardScript = existenceGuard(for: family, language: language) {
                scripts.append(guardScript)
            }
            for script in scripts {
                let url = dir.appendingPathComponent(script.filename)
                try script.source.write(to: url, atomically: true, encoding: .utf8)
                let (code, err) = Self.run(
                    adapter.interpreter, [adapter.evalFlag, adapter.parseOnlyProgram(url.path)],
                    in: dir)
                #expect(code == 0, "\(language)/\(kind) generated unparseable source: \(err)")
            }
        }

        let exceptions = GeneratedSourceFixtures.notebookCheckKindExceptions[language] ?? []
        for kind in NotebookCheckKind.allCases where !exceptions.contains(kind) {
            let generated = renderNotebookCheck(GeneratedSourceFixtures.check(kind: kind), language: language)
            let url = dir.appendingPathComponent(generated.script.filename)
            try generated.script.source.write(to: url, atomically: true, encoding: .utf8)
            let (code, err) = Self.run(
                adapter.interpreter, [adapter.evalFlag, adapter.parseOnlyProgram(url.path)],
                in: dir)
            #expect(code == 0, "\(language)/\(kind) generated unparseable source: \(err)")
        }
    }

    /// The gap this matrix was designed around. Lua's runtime could READ
    /// `_ck_inputs.lua` from day one and its smoke test supplied one as a
    /// fixture — which proved the reader worked and said nothing about whether
    /// anything ever WROTE it. Nothing did, and every per-student input would
    /// have silently been nil.
    ///
    /// So this asserts the round trip: the server renders the file, and the
    /// language reads back the value the server put in it.
    @Test(arguments: AssignmentLanguage.allCases)
    func theInputsFileTheServerWritesIsTheOneTheLanguageReads(
        _ language: AssignmentLanguage
    ) throws {
        let adapter = Self.adapter(for: language)
        guard Self.isAvailable(adapter) else { return }

        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Rendered exactly as the worker and the browser render it: values
        // arrive already-literal in the target language.
        //
        // `holes` carries a null INSIDE a collection, which is not decoration.
        // Each language spells a missing value differently and two of the three
        // spellings are load-bearing: R uses `NA` because `NULL` vanishes from a
        // `list()`, and Lua uses the sentinel `chickadee.NULL` because a `nil`
        // in a table constructor is not stored at all. A scalar-only fixture
        // exercises neither, and the Lua one in particular fails in the worst
        // way — the chunk raises, the reader's `pcall` swallows it, and EVERY
        // per-student value reads as missing rather than anything erroring.
        // C++'s null-in-collection story is REFUSAL at save time — no C++
        // value exists for a JSON null, and `cppRenderabilityIssue` names
        // that at authoring — so its fixture holds a null-free array, and the
        // refusal itself is asserted here: that refusal IS the behaviour the
        // other languages implement with sentinels (`NA`, `chickadee.NULL`).
        let holes: JSONValue =
            language == .cpp
            ? .array([.int(60), .int(20)])
            : .array([.int(60), .null, .int(20)])
        if language == .cpp {
            #expect(JSONValue.array([.int(60), .null, .int(20)]).cppRenderabilityIssue != nil)
        }
        let rendered = language.renderInputsFile([
            "threshold": language.literal(.int(42)),
            "holes": language.literal(holes),
        ])
        try rendered.write(
            to: dir.appendingPathComponent(language.inputsFileName),
            atomically: true, encoding: .utf8)

        let (code, err) = Self.run(
            adapter.interpreter, [adapter.evalFlag, adapter.readInputsProgram("threshold")],
            in: dir)
        #expect(code == 0, "\(language) could not read its own inputs file: \(err)")
    }

    // MARK: - Helpers

    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<this>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-langmatrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Spawned through `/usr/bin/env`, the same way the runner resolves an
    /// interpreter, so "available here" means the same thing it means there.
    static func run(_ interpreter: String, _ args: [String], in dir: URL) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [interpreter] + args
        process.currentDirectoryURL = dir
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { return (-1, String(describing: error)) }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
    }

    static func isAvailable(_ adapter: Adapter) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [adapter.interpreter] + adapter.versionArguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func pythonString(_ s: String) -> String { JSONValue.string(s).pythonLiteral }
    static func rString(_ s: String) -> String { JSONValue.string(s).rLiteral }
    static func luaString(_ s: String) -> String { JSONValue.string(s).luaLiteral }
    static func octString(_ s: String) -> String { JSONValue.string(s).octaveLiteral }
}
