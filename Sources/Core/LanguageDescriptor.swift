// Core/LanguageDescriptor.swift
//
// The FACTS about an assignment language, gathered into one value so adding a
// language is one literal to write rather than a dozen switch arms to find.
//
// WHY A DESCRIPTOR ON A CLOSED ENUM, AND NOT A PROTOCOL OR A CLASS HIERARCHY.
// The question that decides it is not which is more elegant, it is *which one
// makes a missing answer a compile error*:
//
//   * A closed enum with exhaustive switches turns a new language into a
//     worklist. Adding `case lua` produced 26 compile errors, and they WERE the
//     plan. That is the single most valuable property of this type.
//   * A protocol loses it. A new conforming type compiles the moment it exists,
//     every default implementation becomes a silent wrong answer, and
//     `allCases` degrades into a hand-maintained array — which is precisely the
//     "enumerated rather than discovered, fails open" shape this codebase has
//     been bitten by four times (docs/adding-a-xeus-kernel.md). It would
//     reinstate the bug class at the centre of the design.
//   * Inheritance is worse still: its defining feature is the shared default a
//     subclass silently inherits, which is the failure mode itself. It also
//     trades value semantics for reference semantics on something compared,
//     hashed and sent across actors.
//   * Associated values cannot be used at all — `AssignmentLanguage` has a
//     `String` raw type (it is the wire format for `TestProperties.language` in
//     every persisted manifest), and Swift forbids raw values with associated
//     values outright.
//
// Protocols are right elsewhere in this codebase and used there: `ScriptRunner`
// has genuinely different implementations swapped at RUNTIME by a flag. A
// language is closed, chosen at compile time, and two of the three differ by
// one character.
//
// FACTS, AND ONE JUDGEMENT THAT REPLACED THREE. Most of this is plain fact —
// extensions, filenames, kernel aliases, how the language is spelled to a
// student. Those were eight parallel switches and are now eight fields.
//
// `runnerProvidedModules`, `studentModulePrefixes` and
// `supportFilesPathEnvironmentVariable` were a different problem: three
// switches, three chances to copy the neighbour's answer — and the neighbour is
// exactly who you must not copy, since R and Lua land on OPPOSITE answers for
// the same shape. They were not three questions. They were three projections of
// one: `ModuleResolution`, how the language reaches code that is not the
// student's. It is asked once now, and they are derived.
//
// That reduction was checked against three languages this codebase does not
// have (Octave, Java, C++) before it was made — see `ModuleResolution`. Octave
// is why it is one judgement PLUS one fact rather than one judgement alone, and
// C++ is why the reduction stops where it does.

import Foundation

/// How a language reaches code that is not the student's own.
///
/// THE ONE JUDGEMENT. `runnerProvidedModules`, `studentModulePrefixes` and
/// `supportFilesPathEnvironmentVariable` used to be three separate switches,
/// three chances to copy the neighbour's answer by mistake — and the neighbour
/// is exactly who you must not copy, since R and Lua land on opposite answers
/// for the same shape. They are all projections of this single question, so it
/// is asked once and they are derived.
///
/// Scored against three languages this codebase does not have, to check the
/// idea was not overfitted to the three it does:
///
/// | language | resolution | derives correctly? |
/// |---|---|---|
/// | Python | `byName("PYTHONPATH")` + a `sitecustomize` hook | yes |
/// | R | `fileRead` (`source()`) | yes |
/// | Lua | `byName("LUA_PATH")`, cwd already on path | yes |
/// | Octave | `byName("OCTAVE_PATH")`, resolved by filename | yes — but see below |
/// | Java | `byName("CLASSPATH")` | yes |
/// | C++ | none — `#include` is compile-time | n/a, and see below |
///
/// **Octave is why the search-path variable needs a second input.** R is
/// file-based and needs no variable; Octave is *also* file-based in spirit and
/// needs `OCTAVE_PATH`. What actually decides it is not the resolution
/// mechanism but `workingDirectoryIsOnDefaultSearchPath` — a per-implementation
/// accident (Lua puts `./?.lua` on the path, Python and Octave do not). Hence
/// one judgement plus one fact, not one judgement alone.
///
/// **C++ is why this type stops here.** A compiled language reaches other code
/// at compile time, so none of these three fields mean anything for it — but it
/// also would not need them: Chickadee already grades C++ today through a `.sh`
/// suite script and the existing `make` step, with no `AssignmentLanguage`
/// involvement at all. This type is about AUTHORING (generated families,
/// notebook checks, personalization, in-browser kernels), not grading. The
/// place C++ would genuinely break is `literal(_:)` — `JSONValue` is
/// dynamically typed and C++ needs a type for every literal, so `[1, "two"]`
/// has no rendering. That is an impossibility rather than a judgement, and it
/// is recorded in docs/adding-a-xeus-kernel.md rather than anticipated here.
public enum ModuleResolution: Equatable, Sendable {
    /// Code is reached by READING A FILE — R's `source()`. Nothing is
    /// name-addressable, so nothing is importable, no prefix can be declared,
    /// and no search-path variable exists to set.
    case fileRead

    /// Code is reached by NAME, resolved against a search path.
    ///
    /// - Parameter searchPathVariable: the environment variable that extends
    ///   that path, or nil where the language has none.
    /// - Parameter interpreterHookModules: modules the INTERPRETER itself
    ///   auto-loads, as distinct from ones the runner injects. Python's
    ///   `sitecustomize` is the only instance across all six languages
    ///   surveyed; it lives here because it is a property of how that runtime
    ///   resolves modules, not a fourth thing to remember.
    case byName(searchPathVariable: String?, interpreterHookModules: Set<String> = [])
}

/// Files the RUNNER writes into every grading workspace, which are therefore
/// importable in any language that resolves modules by name.
///
/// One constant rather than a per-language list: the runner writes the same
/// things whatever the language, so a per-language copy could only ever be
/// wrong. It was — Python's copy omitted `solution`, while `test_runtime.py`
/// itself special-cases `solution.py`, so a hand-authored `import solution`
/// was reported unsatisfiable by the import guard.
private let runnerInjectedModuleNames: Set<String> = ["test_runtime", "_ck_inputs"]

/// Prefixes of names a student's extracted submission can be loaded under. The
/// concrete name depends on what they upload and is unknowable while authoring,
/// so the guard matches on prefix.
private let studentSubmissionModulePrefixes: [String] = [
    "solution", "submission", "student", "_ck_",
]

/// Everything factual about one assignment language.
///
/// Read it through `AssignmentLanguage.descriptor`. Adding a language means
/// writing one of these — and the compiler will not let you omit a field, so
/// every fact has to be answered.
public struct LanguageDescriptor: Equatable, Sendable {

    /// How the language is written in prose a STUDENT reads — an error about
    /// their upload, a warning about a file that could not be graded.
    ///
    /// Not the raw value: that is a wire token (`r`, `lua`) and "is not a valid
    /// r script" reads like a typo.
    public let displayName: String

    /// Graded-script filename extensions (lowercased) that mark this language.
    /// The single source of truth for the "`.R` script → R assignment" sniff.
    public let scriptExtensions: Set<String>

    /// Extension for scripts Chickadee GENERATES (pattern-family cases,
    /// notebook checks).
    ///
    /// Feeds `spec_hash` and the `TestSetupCache` key, so changing an existing
    /// language's value rewrites every assignment's manifest.
    public let generatedScriptExtension: String

    /// Filename of the per-student grading-inputs file the worker materializes.
    /// Must match byte-for-byte what the language's `test_runtime` reads AND
    /// what the browser's `personalizationInputsSource<X>` writes.
    public let inputsFileName: String

    /// Kernelspec `name` values (and `language_info.name`) that positively mark
    /// a notebook as THIS language.
    ///
    /// Python is deliberately EMPTY and that is not an oversight: it is the
    /// default, reached by falling through when nothing else matched. Giving it
    /// a positive alias set would change how every existing assignment
    /// resolves. Positive detection is for the non-default languages only.
    ///
    /// Populated from the `<lang>KernelNames` statics rather than inlined here,
    /// and that is load-bearing: `scripts/generate-js-constants.sh` parses those
    /// declarations out of the Swift source to write the browser's copy. Inlining
    /// the sets would leave the generator with nothing to find.
    public let notebookKernelNames: Set<String>

    /// The env file a maintainer edits to add a package to this language's
    /// browser-grading kernel, named in the authoring rejection message.
    public let kernelEnvironmentFileName: String

    /// How a missing dependency presents to a student at grade time, phrased for
    /// that same rejection message.
    public let missingDependencyFailureDescription: String

    /// The command a runner probes to decide whether it can grade this
    /// language, with the arguments that make it print a version and exit 0.
    ///
    /// The ARGUMENTS are per-language for a reason learned the hard way:
    /// `--version` works for python3 and R and **fails on lua**, which prints a
    /// usage message and exits 1. A hardcoded `--version` left Lua undetectable
    /// by capability matching — so no runner advertised it, and an assignment
    /// requiring it matched nothing and queued forever.
    ///
    /// A KNOWN ASYMMETRY, deliberately preserved: R is probed with `R` while
    /// the worker invokes `Rscript`. Both ship in `r-base`, and the two print
    /// differently-shaped version strings — changing the probe would change the
    /// version text deployed runners already advertise, which an assignment's
    /// `minimumVersion` requirement may be matching against.
    public let interpreterProbe: InterpreterProbe

    /// THE ONE JUDGEMENT — see `ModuleResolution`. Three former switches derive
    /// from this, so it is asked once instead of three times.
    public let moduleResolution: ModuleResolution

    /// THE ONE FACT the resolution mechanism cannot supply: whether the
    /// language's default search path already contains the working directory.
    ///
    /// Separate because it does not follow from the mechanism — Lua puts
    /// `./?.lua` on `package.path` and so needs no variable set, while Python
    /// and Octave resolve by name just the same and do. Setting a variable that
    /// is not needed is not harmless either: assigning `LUA_PATH` REPLACES the
    /// default path unless it contains `;;`, which would break the very lookup
    /// it was meant to enable.
    public let workingDirectoryIsOnDefaultSearchPath: Bool

    public struct InterpreterProbe: Equatable, Sendable {
        public let command: String
        public let versionArguments: [String]

        public init(command: String, versionArguments: [String]) {
            self.command = command
            self.versionArguments = versionArguments
        }
    }

    public init(
        displayName: String,
        scriptExtensions: Set<String>,
        generatedScriptExtension: String,
        inputsFileName: String,
        notebookKernelNames: Set<String>,
        kernelEnvironmentFileName: String,
        missingDependencyFailureDescription: String,
        interpreterProbe: InterpreterProbe,
        moduleResolution: ModuleResolution,
        workingDirectoryIsOnDefaultSearchPath: Bool
    ) {
        self.displayName = displayName
        self.scriptExtensions = scriptExtensions
        self.generatedScriptExtension = generatedScriptExtension
        self.inputsFileName = inputsFileName
        self.notebookKernelNames = notebookKernelNames
        self.kernelEnvironmentFileName = kernelEnvironmentFileName
        self.missingDependencyFailureDescription = missingDependencyFailureDescription
        self.interpreterProbe = interpreterProbe
        self.moduleResolution = moduleResolution
        self.workingDirectoryIsOnDefaultSearchPath = workingDirectoryIsOnDefaultSearchPath
    }
}

extension AssignmentLanguage {

    /// The facts about this language, in one place.
    ///
    /// EXHAUSTIVE, like everything else on this type: a new case does not
    /// compile until it supplies a descriptor, and the descriptor's initialiser
    /// does not compile until every fact is answered.
    public var descriptor: LanguageDescriptor {
        switch self {
        case .python:
            return LanguageDescriptor(
                displayName: "Python",
                scriptExtensions: ["py"],
                generatedScriptExtension: "py",
                inputsFileName: "_ck_inputs.py",
                notebookKernelNames: [],
                kernelEnvironmentFileName: "environment-python.yml",
                missingDependencyFailureDescription: "an ImportError",
                interpreterProbe: .init(command: "python3", versionArguments: ["--version"]),
                moduleResolution: .byName(
                    searchPathVariable: "PYTHONPATH",
                    interpreterHookModules: ["sitecustomize"]),
                // The driver runs from a temp directory with cwd set to the
                // support-files directory, so `sys.path[0]` is the driver's
                // directory and not the one the helpers are in.
                workingDirectoryIsOnDefaultSearchPath: false
            )
        case .r:
            return LanguageDescriptor(
                displayName: "R",
                scriptExtensions: ["r"],
                generatedScriptExtension: "R",
                inputsFileName: "_ck_inputs.R",
                notebookKernelNames: AssignmentLanguage.rKernelNames,
                kernelEnvironmentFileName: "environment-r.yml",
                missingDependencyFailureDescription: "an error from library()",
                interpreterProbe: .init(command: "R", versionArguments: ["--version"]),
                // `source("test_runtime.R")` is a file read, not a module load:
                // there is no name to resolve, so nothing is importable and no
                // guard could reject anything.
                moduleResolution: .fileRead,
                workingDirectoryIsOnDefaultSearchPath: true
            )
        case .lua:
            return LanguageDescriptor(
                displayName: "Lua",
                scriptExtensions: ["lua"],
                generatedScriptExtension: "lua",
                inputsFileName: "_ck_inputs.lua",
                notebookKernelNames: AssignmentLanguage.luaKernelNames,
                kernelEnvironmentFileName: "environment-lua.yml",
                missingDependencyFailureDescription: "an error from require()",
                // `-v`, not `--version` — see `interpreterProbe`'s note.
                interpreterProbe: .init(command: "lua", versionArguments: ["-v"]),
                // `require("test_runtime")` IS a module load — the same shape as
                // R's and the opposite answer, which is why this is asked per
                // language rather than inherited.
                moduleResolution: .byName(searchPathVariable: "LUA_PATH"),
                // Verified rather than assumed: `lua -e 'print(package.path)'`
                // ends with `./?.lua;./?/init.lua`.
                workingDirectoryIsOnDefaultSearchPath: true
            )
        }
    }
}

// MARK: - Derived from the resolution mechanism
//
// Three properties that used to be three hand-written switches. They are
// computed here so a new language answers ONE question (plus one fact) rather
// than three — and cannot answer them inconsistently, which was possible before
// and had happened.

extension AssignmentLanguage {

    /// Modules the runner injects into the grading workspace, importable even
    /// though no kernel package ships them.
    ///
    /// Empty for a `fileRead` language by FACT, not omission: R reaches its
    /// runtime with `source()`, so there is no name for a guard to check.
    public var runnerProvidedModules: Set<String> {
        switch descriptor.moduleResolution {
        case .fileRead:
            return []
        case .byName(_, let interpreterHookModules):
            return runnerInjectedModuleNames.union(interpreterHookModules)
        }
    }

    /// Prefixes of extracted-submission modules the import guard must not
    /// reject. Empty for a `fileRead` language, for the same reason.
    public var studentModulePrefixes: [String] {
        switch descriptor.moduleResolution {
        case .fileRead: return []
        case .byName: return studentSubmissionModulePrefixes
        }
    }

    /// Environment variable that puts the assignment's support files on this
    /// language's module search path when the personalization driver runs, or
    /// nil when none is needed.
    ///
    /// Needs BOTH inputs: the mechanism supplies which variable exists, and
    /// `workingDirectoryIsOnDefaultSearchPath` decides whether setting it would
    /// achieve anything. Octave is the case that proves the second is required
    /// — file-resolved like R, yet it does need `OCTAVE_PATH`.
    public var supportFilesPathEnvironmentVariable: String? {
        switch descriptor.moduleResolution {
        case .fileRead:
            return nil
        case .byName(let searchPathVariable, _):
            return descriptor.workingDirectoryIsOnDefaultSearchPath ? nil : searchPathVariable
        }
    }
}
