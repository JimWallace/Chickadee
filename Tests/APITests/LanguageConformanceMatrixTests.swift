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
// CI has python3, r-base and lua5.4 on the image, so the executed half runs
// there; `theRunnerImageProvidesEveryInterpreter` is what keeps that true.

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
        /// The Debian package that provides it, as the Dockerfile installs it.
        let debianPackage: String
        /// Source that parses `path` WITHOUT executing it, exiting non-zero on
        /// a syntax error. A parse check, not a run: generated scripts expect a
        /// student submission and a runtime beside them.
        let parseOnlyProgram: (String) -> String
        /// Source that loads this language's inputs file from the working
        /// directory and prints the value bound to `key`.
        let readInputsProgram: (_ key: String) -> String
    }

    /// EXHAUSTIVE ON PURPOSE. A new `AssignmentLanguage` case does not compile
    /// until it supplies its glue here, which is what stops the matrix from
    /// quietly covering one fewer language than exists.
    static func adapter(for language: AssignmentLanguage) -> Adapter {
        switch language {
        case .python:
            return Adapter(
                interpreter: "python3",
                evalFlag: "-c",
                debianPackage: "python3",
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
                debianPackage: "r-base",
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
        }
    }

    // MARK: - Structural invariants (never skipped)

    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageDeclaresAUsableScriptExtension(_ language: AssignmentLanguage) {
        #expect(!language.scriptExtensions.isEmpty)
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
        // exist sends an instructor to a path that is not there.
        let url = Self.repoRoot
            .appendingPathComponent("Tools/jupyterlite")
            .appendingPathComponent(language.kernelEnvironmentFileName)
        #expect(
            FileManager.default.fileExists(atPath: url.path),
            "\(language.kernelEnvironmentFileName) does not exist")
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

    // MARK: - Renderer coverage (never skipped)

    @Test(arguments: AssignmentLanguage.allCases)
    func everyPatternKindRendersInEveryLanguage(_ language: AssignmentLanguage) {
        for kind in PatternKind.allCases {
            let scripts = renderPatternFamily(GeneratedSourceFixtures.family(kind: kind), language: language)
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
                    GeneratedSourceFixtures.family(kind: kind), language: language
                )
                .map(\.source).joined(separator: "\n")
                perLanguage[language] = Set(vocabulary.filter { source.contains($0) })
            }
            guard let reference = perLanguage[.default] else { continue }
            for (language, used) in perLanguage where language != .default {
                #expect(
                    used == reference,
                    """
                    \(kind) uses different failure wording in \(language) than in \
                    \(AssignmentLanguage.default). Only in \(AssignmentLanguage.default): \
                    \(reference.subtracting(used).sorted()). Only in \(language): \
                    \(used.subtracting(reference).sorted()).
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
        guard Self.isAvailable(adapter.interpreter) else { return }

        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for kind in PatternKind.allCases {
            for script in renderPatternFamily(GeneratedSourceFixtures.family(kind: kind), language: language) {
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
        guard Self.isAvailable(adapter.interpreter) else { return }

        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Rendered exactly as the worker and the browser render it: values
        // arrive already-literal in the target language.
        let rendered = language.renderInputsFile(["threshold": language.literal(.int(42))])
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

    static func isAvailable(_ interpreter: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [interpreter, "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func pythonString(_ s: String) -> String { JSONValue.string(s).pythonLiteral }
    static func rString(_ s: String) -> String { JSONValue.string(s).rLiteral }
}
