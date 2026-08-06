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
// WHAT IS DELIBERATELY *NOT* HERE. This holds facts — extensions, filenames,
// kernel aliases, how the language is spelled to a student. It does NOT hold
// the three answers that are JUDGEMENTS:
//
//   `runnerProvidedModules`, `studentModulePrefixes`,
//   `supportFilesPathEnvironmentVariable`
//
// Those stay as their own documented switches on `AssignmentLanguage`, because
// for them the reasoning IS the value. `runnerProvidedModules` is empty for R
// and non-empty for Lua — the same shape with the opposite answer, because R
// reaches its runtime with a file read and Lua with a real module load. Flatten
// that into a struct literal and it becomes three strings someone copies from
// the neighbour, which is the exact mistake the runbook shouts about. A field in
// a literal invites filling in; a switch arm with four lines of rationale above
// it invites reading.

import Foundation

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
        interpreterProbe: InterpreterProbe
    ) {
        self.displayName = displayName
        self.scriptExtensions = scriptExtensions
        self.generatedScriptExtension = generatedScriptExtension
        self.inputsFileName = inputsFileName
        self.notebookKernelNames = notebookKernelNames
        self.kernelEnvironmentFileName = kernelEnvironmentFileName
        self.missingDependencyFailureDescription = missingDependencyFailureDescription
        self.interpreterProbe = interpreterProbe
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
                interpreterProbe: .init(command: "python3", versionArguments: ["--version"])
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
                interpreterProbe: .init(command: "R", versionArguments: ["--version"])
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
                interpreterProbe: .init(command: "lua", versionArguments: ["-v"])
            )
        }
    }
}
