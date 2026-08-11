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
/// Scored against three languages this codebase did not have at the time, to
/// check the idea was not overfitted to the three it did:
///
/// | language | resolution | derives correctly? |
/// |---|---|---|
/// | Python | `byName("PYTHONPATH")` + a `sitecustomize` hook | yes |
/// | R | `fileRead` (`source()`) | yes |
/// | Lua | `byName("LUA_PATH")`, cwd already on path | yes |
/// | Octave | `byName("OCTAVE_PATH")`, cwd already on path | yes — prediction was wrong, see below |
/// | Java | `byName("CLASSPATH")` | yes |
/// | C++ | none — `#include` is compile-time | n/a, and see below |
///
/// **The fourth language arrived, and measurement corrected the survey.** This
/// table originally predicted Octave needs `OCTAVE_PATH` set because its cwd
/// is off the default path — and `octave-cli --eval "path"` shows the
/// opposite: `.` is the FIRST entry of Octave's default load path (verified on
/// the native 8.4 CLI and the wasm 10.3 kernel alike), so Octave lands like
/// Lua and no variable is set. The SHAPE survives on Python's evidence — a
/// by-name language whose cwd is genuinely off the path is real, so the
/// mechanism alone cannot decide — but the Octave row was an armchair answer,
/// and it is exactly why `workingDirectoryIsOnDefaultSearchPath` carries a
/// "verify, do not assume" instruction. Hence one judgement plus one measured
/// fact, not one judgement alone.
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

/// Whether — and how — a language appears in the embedded editor.
///
/// THE SECOND JUDGEMENT, alongside `ModuleResolution`. Four descriptor fields
/// used to presuppose a vendored JupyterLite kernel (the env file, the kernel
/// name, its display label, and how a missing package presents at grade
/// time). That was fine while it was true of every language, but it baked the
/// assumption into the type: a language without a kernel could not be
/// expressed at all. This enum makes the assumption a stated answer instead —
/// and gathers the four facts behind it, so they exist exactly when a kernel
/// does.
///
/// - `notebookKernel`: the language has a vendored xeus kernel; it appears in
///   the editor's picker, notebooks normalize onto it, and browser grading
///   can run it. Every current language answers this — which is the vendored-
///   kernel rule ("a language is supported or it is not present",
///   docs/adding-a-xeus-kernel.md) expressed in types.
/// - `uploadOnly`: no kernel is vendored, deliberately. The language's
///   assignments are upload-only (`SubmissionMode.uploadOnly`) and grade on
///   the native worker exclusively. This is the shape for compiled languages
///   graded through the shell-script + makefile path — the browser cannot run
///   the course's real toolchain, and grading a *different* compiler than the
///   course teaches is a pedagogy defect no substrate work removes (see
///   docs/cpp-assignment-language-decision.md §3). Nothing dangles: with no
///   kernel in the picker, the language cannot be authored in the editor, so
///   the rule above is satisfied from the other direction.
public enum EditorSupport: Equatable, Sendable {
    /// A vendored kernel serves this language in the editor and the browser
    /// grader.
    ///
    /// - `environmentFileName`: the env file a maintainer edits to add a
    ///   package to the browser-grading kernel, named in the authoring
    ///   rejection message.
    /// - `kernelName` / `kernelDisplayName`: the vendored JupyterLite kernel a
    ///   notebook in this language is normalized onto, and the friendly label
    ///   shown beside it. `normalizeNotebookForJupyterLite` collapses every
    ///   alias in `notebookKernelNames` onto `kernelName` so the editor can
    ///   attach a kernel; the display name deliberately omits the language
    ///   version the kernelspec carries, so a kernel rebuild does not churn
    ///   every stored notebook.
    /// - `missingDependencyFailureDescription`: how a missing dependency
    ///   presents to a student at grade time, phrased for that same rejection
    ///   message.
    /// - `gradingWorkerScript`: the Web Worker `Public/browser-runner.js`
    ///   spawns to grade this language in the browser. It lives here for the
    ///   same reason the kernel name does — it exists exactly when a kernel
    ///   does — and because it was previously a fact held in two places that
    ///   nothing connected: a hand-written path in `browser-runner.js` and a
    ///   hand-written entry in `NotebookAssetIsolationMiddleware
    ///   .isolatedWorkerScripts`. A worker missing from the allowlist is
    ///   refused by the browser on an isolated page, `ensureReady` throws, and
    ///   the submission silently fails over to the native worker: right marks,
    ///   none of the speed. That is how #1274 shipped browser-graded R no
    ///   isolated engine ever ran.
    case notebookKernel(
        environmentFileName: String,
        kernelName: String,
        kernelDisplayName: String,
        missingDependencyFailureDescription: String,
        gradingWorkerScript: String)

    /// No vendored kernel, deliberately — submissions arrive as file uploads
    /// and grade on the native worker only.
    case uploadOnly
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
/// How this language's function definitions are read out of a solution
/// notebook — the IMPLEMENTATION, not a claim that one exists.
///
/// WHY THE PATTERNS LIVE HERE. The first version of multi-language scanning put
/// a `Bool` on `AuthoringLanguageFacts` and the parser somewhere else, which is
/// the shape that had already drifted once: a capability can be claimed and not
/// supplied, and nothing catches it until an instructor is told their solution
/// is empty. Carrying the patterns makes the claim and the implementation the
/// same object — a seventh language either writes them or says
/// `noSolutionNotebook`, and there is no third answer that compiles.
///
/// I ARGUED AGAINST THIS AND WAS WRONG. The case against a pattern table was
/// that the four syntaxes are not one shape with different tokens — Octave puts
/// return variables before the name, Lua has three definition forms, R's is an
/// assignment whose right-hand side is a `function` literal. That is all true,
/// and it turned out not to matter: written out, every one of them reduces to
/// an ordered list of alternatives whose first group is the name and second is
/// the parameter list. Python is the single exception, and it is called out as
/// its own case rather than bent into the table.
public enum FunctionScanSyntax: Equatable, Sendable {

    /// Python's `def` statements, read by the full parser — the only one that
    /// also recovers type annotations, defaults, the return type and a
    /// docstring, because Python is the only one of the six that writes them.
    case pythonDefStatements

    /// Ordered regex alternatives, first match wins. Capture group 1 must be
    /// the function name and group 2 the raw parameter list.
    ///
    /// No type information is recovered, because none of these languages has
    /// parameter annotations to recover. That is the same state an un-annotated
    /// Python function already produces and the editor already handles.
    case definitionPatterns([String])

    /// The language has no solution notebook to scan, because it has no
    /// notebook workflow at all (`EditorSupport.uploadOnly`).
    ///
    /// Structural, not a missing parser — which is why the reason is derived
    /// from `editorSupport` rather than written out per language.
    case noSolutionNotebook
}

/// Where a pattern-family case's expected value is computed by running the
/// instructor's solution.
///
/// IN-PAGE WHEREVER A KERNEL EXISTS. Not chosen by grading mode: the editor's
/// job is in-browser authoring and verification, and making an author wait on a
/// server round-trip to see what their solution returns defeats it. An
/// instructor can tolerate a lazy kernel boot — the worker is spawned on first
/// use, not on page load — and in exchange the value is computed by the same
/// kernel that will grade a browser-graded submission.
public enum AutoComputeSubstrate: Equatable, Sendable {

    /// A vendored xeus kernel, run in the named Web Worker.
    case inPageKernel(workerScript: String)

    /// No kernel is vendored for this language, so the server's interpreter
    /// evaluates it (`PersonalizationEvaluator`).
    ///
    /// Both languages here are upload-only, and for the same reason they have
    /// no kernel: C++ by decision (grading a different compiler than the course
    /// teaches is a pedagogy defect), Racket by circumstance (no Scheme-family
    /// kernel exists on the channel). If one ever gains a kernel, this arm is
    /// what changes.
    case serverDriver
}

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

    /// The extension a SOURCE FILE in this language carries — what a notebook's
    /// code becomes when it is extracted, and what `solution.<ext>` is called.
    ///
    /// Distinct from `generatedScriptExtension`, and C++ is why: a generated
    /// C++ case is a `.sh` wrapper, while its extracted source is `.cpp`. It is
    /// also distinct from `scriptExtensions`, which is a Set and has no
    /// deterministic first element (C++ claims `cpp`, `h` and `hpp`).
    ///
    /// A field because it was two identical hand-written switches — the
    /// worker's submission staging and its notebook extractor — and a third was
    /// about to be added for the server-side solution extractor. Three copies of
    /// one fact is the shape this file exists to stop.
    public let sourceFileExtension: String

    /// How this language opens a single-line comment: `#`, `%`, `--`, `;` or
    /// `//`.
    ///
    /// THE ONLY COPY. There were two: this field, and a `lineCommentLeader`
    /// switch on `AssignmentLanguage` written for the same purpose a release
    /// later. They disagreed about Octave — `#` here, `%` there — and neither
    /// was wrong enough to break, because Octave accepts both. So the inputs
    /// file got `%`, the starter-notebook scaffold and the inlined-inputs
    /// banner got `#`, and every other Octave byte the system emits
    /// (`test_runtime.m`, every generated case) got `%`. Two spellings of one
    /// fact, drifting quietly, in the file whose entire thesis is one place per
    /// fact. `%` won: it is what Octave itself is written in here, and the one
    /// of the two that MATLAB also accepts.
    ///
    /// A FACT, and one that used to be assumed. `TestScriptVariablePrepender`
    /// wrote a `#`-prefixed banner above the inputs it inlines into a
    /// hand-written test, in every language — correct for Python, R, Octave and
    /// shell, and a syntax error in the other three. `#` is Lua's length
    /// operator, starts a Racket reader form, and is a C++ preprocessor
    /// directive, so a Lua or Racket assignment with global inputs plus a
    /// hand-written test produced a file its interpreter refused to load.
    ///
    /// Exhaustive like the rest of this type, so a seventh language answers it
    /// rather than inheriting Python's.
    public let lineCommentPrefix: String

    /// How this language's definitions are read out of a solution notebook.
    /// See `FunctionScanSyntax` — it carries the patterns, not a claim.
    public let functionScan: FunctionScanSyntax

    /// Where a case's expected value is computed. See `AutoComputeSubstrate`.
    public let autoCompute: AutoComputeSubstrate

    /// Filename of the per-student grading-inputs file the worker materializes.
    /// Must match byte-for-byte what the language's `test_runtime` reads AND
    /// what the browser's `personalizationInputsSource<X>` writes.
    public let inputsFileName: String

    /// Kernelspec `name` values (and `language_info.name`) that positively mark
    /// a notebook as THIS language.
    ///
    /// EVERY language with a notebook workflow answers this, Python included.
    /// This doc used to say the opposite — "Python is deliberately EMPTY and
    /// that is not an oversight" — which was true when written and stopped
    /// being true when resolution became Optional and Python started matching
    /// positively like everything else. The two upload-only languages are the
    /// empty ones now, and for a structural reason: no kernel exists to claim
    /// an alias for.
    ///
    /// The distinction the old doc was protecting is real and now lives in
    /// `resolve`: "this is Python" and "nothing here names a language" used to
    /// be the same answer, and every silent misroute in this area descended
    /// from that. It is `nil` that means the second thing, not Python.
    ///
    /// Populated from the `<lang>KernelNames` statics rather than inlined here,
    /// and that is load-bearing: `scripts/generate-js-constants.sh` parses those
    /// declarations out of the Swift source to write the browser's copy. Inlining
    /// the sets would leave the generator with nothing to find.
    public let notebookKernelNames: Set<String>

    /// Whether the language has a vendored editor/browser-grading kernel, and
    /// the kernel facts when it does — see `EditorSupport`. Was four flat
    /// fields (`kernelEnvironmentFileName`, `jupyterLiteKernelName` and its
    /// display name, `missingDependencyFailureDescription`) that presupposed a
    /// kernel exists; folding them behind this judgement is what lets a
    /// kernel-less, upload-only language be expressed at all.
    public let editorSupport: EditorSupport

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

    /// Whether grading this language EXECUTES a file it just produced, so that
    /// "the tool is installed" is not the same question as "a job will run".
    ///
    /// False for every interpreted language: the runner spawns the interpreter
    /// that `interpreterProbe` found and hands it a script, so a successful
    /// probe and a successful invocation are the same act. True for C++, where
    /// the generated wrapper compiles a binary into the working directory and
    /// then `exec`s it — two capabilities, of which the probe tested one.
    ///
    /// The distinction is not theoretical. `g++ --version` succeeds on a runner
    /// whose work directory is mounted `noexec`; the runner then advertises
    /// `cpp`, `RunnerLanguageGate` routes every C++ job to it, and each one dies
    /// at `exec` with `Permission denied` — a message that reads as a broken
    /// test script and gets debugged as one. The descriptor used to claim
    /// "probe and invocation cannot skew" because both run `g++`; they skew on
    /// the step after `g++`.
    public let capabilityRequiresExecutableOutput: Bool

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
        sourceFileExtension: String,
        lineCommentPrefix: String,
        functionScan: FunctionScanSyntax,
        autoCompute: AutoComputeSubstrate,
        inputsFileName: String,
        notebookKernelNames: Set<String>,
        editorSupport: EditorSupport,
        interpreterProbe: InterpreterProbe,
        moduleResolution: ModuleResolution,
        workingDirectoryIsOnDefaultSearchPath: Bool,
        capabilityRequiresExecutableOutput: Bool
    ) {
        self.displayName = displayName
        self.scriptExtensions = scriptExtensions
        self.generatedScriptExtension = generatedScriptExtension
        self.sourceFileExtension = sourceFileExtension
        self.lineCommentPrefix = lineCommentPrefix
        self.functionScan = functionScan
        self.autoCompute = autoCompute
        self.inputsFileName = inputsFileName
        self.notebookKernelNames = notebookKernelNames
        self.editorSupport = editorSupport
        self.interpreterProbe = interpreterProbe
        self.moduleResolution = moduleResolution
        self.workingDirectoryIsOnDefaultSearchPath = workingDirectoryIsOnDefaultSearchPath
        self.capabilityRequiresExecutableOutput = capabilityRequiresExecutableOutput
    }
}

extension AssignmentLanguage {

    /// The facts about this language, in one place.
    ///
    /// EXHAUSTIVE, like everything else on this type: a new case does not
    /// compile until it supplies a descriptor, and the descriptor's initialiser
    /// does not compile until every fact is answered.
    ///
    /// The switch returns a STORED static rather than building a descriptor
    /// literal per access, which is what it used to do. Every fact on this type
    /// is read through here — `scriptExtensions`, `inputsFileName`,
    /// `notebookKernelNames` and the rest are all one-line forwarders — so a
    /// per-access literal meant every one of them allocated four Sets, two
    /// Arrays and a dozen Strings to answer a question whose answer is a
    /// compile-time constant. Measured at 134 ns per access, and the callers
    /// are loops: `init?(scriptExtension:)` walks `allCases`, and
    /// `gradedScriptLanguage` used to walk `allCases` × suite entries on top of
    /// that. A plain `.sh` suite of 40 entries — the system's original mode and
    /// a fully supported one — cost **1.27 ms** to resolve, on the worker
    /// claim path and every instructor page render.
    ///
    /// The switch is kept exactly as it was: it is the compile-forced worklist
    /// that is the whole point of this type. Only the literal moved.
    public var descriptor: LanguageDescriptor {
        switch self {
        case .python: return Self.pythonDescriptor
        case .r: return Self.rDescriptor
        case .lua: return Self.luaDescriptor
        case .octave: return Self.octaveDescriptor
        case .cpp: return Self.cppDescriptor
        case .racket: return Self.racketDescriptor
        }
    }

    private static let pythonDescriptor = LanguageDescriptor(
        displayName: "Python",
        scriptExtensions: ["py"],
        generatedScriptExtension: "py",
        sourceFileExtension: "py",
        lineCommentPrefix: "#",
        functionScan: .pythonDefStatements,
        autoCompute: .inPageKernel(workerScript: "/python-eval-worker.js"),
        inputsFileName: "_ck_inputs.py",
        notebookKernelNames: AssignmentLanguage.pythonKernelNames,
        editorSupport: .notebookKernel(
            environmentFileName: "environment-python.yml",
            kernelName: "xpython",
            kernelDisplayName: "Python (xeus-python)",
            missingDependencyFailureDescription: "an ImportError",
            gradingWorkerScript: "/python-grading-worker.js"),
        interpreterProbe: .init(command: "python3", versionArguments: ["--version"]),
        moduleResolution: .byName(
            searchPathVariable: "PYTHONPATH",
            interpreterHookModules: ["sitecustomize"]),
        // The driver runs from a temp directory with cwd set to the
        // support-files directory, so `sys.path[0]` is the driver's
        // directory and not the one the helpers are in.
        workingDirectoryIsOnDefaultSearchPath: false,
        // Interpreted: the runner spawns the probed interpreter on a
        // script, so probing IS invoking. Nothing is produced to execute.
        capabilityRequiresExecutableOutput: false
    )
    private static let rDescriptor = LanguageDescriptor(
        displayName: "R",
        scriptExtensions: ["r"],
        generatedScriptExtension: "R",
        sourceFileExtension: "R",
        lineCommentPrefix: "#",
        functionScan: .definitionPatterns([
            #"^([A-Za-z._][A-Za-z0-9._]*)\s*(?:<-|=)\s*function\s*\(([^)]*)\)"#
        ]),
        autoCompute: .inPageKernel(workerScript: "/r-eval-worker.js"),
        inputsFileName: "_ck_inputs.R",
        notebookKernelNames: AssignmentLanguage.rKernelNames,
        editorSupport: .notebookKernel(
            environmentFileName: "environment-r.yml",
            kernelName: "xr",
            kernelDisplayName: "R (xeus-r)",
            missingDependencyFailureDescription: "an error from library()",
            gradingWorkerScript: "/r-grading-worker.js"),
        interpreterProbe: .init(command: "R", versionArguments: ["--version"]),
        // `source("test_runtime.R")` is a file read, not a module load:
        // there is no name to resolve, so nothing is importable and no
        // guard could reject anything.
        moduleResolution: .fileRead,
        workingDirectoryIsOnDefaultSearchPath: true,
        // Interpreted: the runner spawns the probed interpreter on a
        // script, so probing IS invoking. Nothing is produced to execute.
        capabilityRequiresExecutableOutput: false
    )
    private static let luaDescriptor = LanguageDescriptor(
        displayName: "Lua",
        scriptExtensions: ["lua"],
        generatedScriptExtension: "lua",
        sourceFileExtension: "lua",
        lineCommentPrefix: "--",
        functionScan: .definitionPatterns([
            #"^(?:local\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)"#,
            #"^(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function\s*\(([^)]*)\)"#,
        ]),
        autoCompute: .inPageKernel(workerScript: "/lua-eval-worker.js"),
        inputsFileName: "_ck_inputs.lua",
        notebookKernelNames: AssignmentLanguage.luaKernelNames,
        editorSupport: .notebookKernel(
            environmentFileName: "environment-lua.yml",
            kernelName: "xlua",
            kernelDisplayName: "Lua (xeus-lua)",
            missingDependencyFailureDescription: "an error from require()",
            gradingWorkerScript: "/lua-grading-worker.js"),
        // `-v`, not `--version` — see `interpreterProbe`'s note.
        interpreterProbe: .init(command: "lua", versionArguments: ["-v"]),
        // `require("test_runtime")` IS a module load — the same shape as
        // R's and the opposite answer, which is why this is asked per
        // language rather than inherited.
        moduleResolution: .byName(searchPathVariable: "LUA_PATH"),
        // Verified rather than assumed: `lua -e 'print(package.path)'`
        // ends with `./?.lua;./?/init.lua`.
        workingDirectoryIsOnDefaultSearchPath: true,
        // Interpreted: the runner spawns the probed interpreter on a
        // script, so probing IS invoking. Nothing is produced to execute.
        capabilityRequiresExecutableOutput: false
    )
    private static let octaveDescriptor = LanguageDescriptor(
        displayName: "Octave",
        scriptExtensions: ["m"],
        generatedScriptExtension: "m",
        sourceFileExtension: "m",
        // `%`, not `#`. Octave accepts both, which is why the two copies of
        // this fact disagreed for four releases without anything failing — see
        // the field's doc. `%` is what every other Octave byte here uses.
        lineCommentPrefix: "%",
        functionScan: .definitionPatterns([
            #"^function\s*(?:\[[^\]]*\]|[A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)"#,
            #"^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)"#,
        ]),
        autoCompute: .inPageKernel(workerScript: "/octave-eval-worker.js"),
        inputsFileName: "_ck_inputs.m",
        notebookKernelNames: AssignmentLanguage.octaveKernelNames,
        editorSupport: .notebookKernel(
            environmentFileName: "environment-octave.yml",
            kernelName: "xoctave",
            kernelDisplayName: "Octave (xeus-octave)",
            missingDependencyFailureDescription: "an undefined-function error",
            gradingWorkerScript: "/octave-grading-worker.js"),
        // `octave-cli --version` prints "GNU Octave, version N" and
        // exits 0 (verified on 8.4.0). The worker invokes the same
        // binary, so probe and invocation cannot skew.
        interpreterProbe: .init(command: "octave-cli", versionArguments: ["--version"]),
        // `chickadee = test_runtime()` IS a by-name load: the file is
        // found through Octave's load path, not read by filename.
        moduleResolution: .byName(searchPathVariable: "OCTAVE_PATH"),
        // Verified rather than assumed, per this type's own rule —
        // and the verification OVERTURNED the survey's prediction:
        // `octave-cli --eval "path"` lists `.` first, so the working
        // directory is on the default path and no OCTAVE_PATH is set.
        workingDirectoryIsOnDefaultSearchPath: true,
        // Interpreted: the runner spawns the probed interpreter on a
        // script, so probing IS invoking. Nothing is produced to execute.
        capabilityRequiresExecutableOutput: false
    )
    private static let cppDescriptor = LanguageDescriptor(
        displayName: "C++",
        // Marks hand-added `.cpp` suite entries as this language's.
        // Such an entry is not directly runnable (there is no C++
        // interpreter case, deliberately) — the runner classifies it
        // unsupported and errors it, which is the honest outcome for
        // a graded script that needs compiling. Generated cases are
        // `.sh` wrappers instead; see `generatedScriptExtension`.
        scriptExtensions: ["cpp", "h", "hpp"],
        // The generated case IS a shell script (heredoc source →
        // `g++` → run the binary), so it rides the original
        // shell-script contract and the runner needs no new
        // dispatch. Unique across languages like every other value
        // here — no other language generates `.sh`.
        generatedScriptExtension: "sh",
        sourceFileExtension: "cpp",
        lineCommentPrefix: "//",
        functionScan: .noSolutionNotebook,
        autoCompute: .serverDriver,
        inputsFileName: "_ck_inputs.hpp",
        // No notebook workflow, so no kernel aliases to claim — like
        // Python's empty set, but for the opposite reason (nothing to
        // detect, rather than default-by-fallthrough).
        notebookKernelNames: [],
        // The first language to answer this honestly: no vendored
        // kernel, upload-only submissions, native-worker grading.
        // The browser cannot run the course's real g++, and grading
        // a different compiler than the course teaches is the
        // pedagogy defect the C++ design settled on avoiding
        // (docs/cpp-support.md).
        editorSupport: .uploadOnly,
        // `g++ --version` prints a version line and exits 0
        // (verified on 13.3.0). The generated wrappers invoke the
        // same binary, so probe and invocation cannot skew.
        interpreterProbe: .init(command: "g++", versionArguments: ["--version"]),
        // `#include` IS a file read — at compile time rather than
        // run time, but the shape is R's, not Python's: nothing is
        // name-addressable, no search-path variable exists to set,
        // and the derivations (no runner-provided modules, no
        // student prefixes, no path env var) are all correct for it.
        moduleResolution: .fileRead,
        // Quoted includes resolve relative to the INCLUDING file's
        // directory by rule, so everything a generated test includes
        // sits beside it and nothing needs setting. (Unused by the
        // fileRead derivations; stated because the field must be.)
        workingDirectoryIsOnDefaultSearchPath: true,
        // The generated wrapper compiles a binary and `exec`s it, so a
        // runner must be able to run what g++ writes into its work
        // directory — not merely own a g++. See the property's doc.
        capabilityRequiresExecutableOutput: true
    )
    private static let racketDescriptor = LanguageDescriptor(
        displayName: "Racket",
        // `.rkt` only. `.ss` and `.scm` are Scheme's historical
        // extensions and DrRacket still opens them, but no Waterloo
        // course submits them and claiming an extension is how a
        // language steals another's files — the uniqueness invariant
        // exists for exactly that.
        scriptExtensions: ["rkt"],
        // Unlike C++, the generated test IS the language: Racket is
        // interpreted, so `racket test.rkt` runs it directly under the
        // ordinary shell-script contract. No wrapper, no build step.
        generatedScriptExtension: "rkt",
        sourceFileExtension: "rkt",
        lineCommentPrefix: ";",
        functionScan: .noSolutionNotebook,
        autoCompute: .serverDriver,
        inputsFileName: "_ck_inputs.rkt",
        // No kernel exists to claim aliases for. Empty for the same
        // reason as C++ — nothing to detect — not Python's
        // default-by-fallthrough.
        notebookKernelNames: [],
        // No xeus kernel on the channel, so no editor and no notebook
        // workflow. Contingent rather than principled: see the enum
        // case's doc for why that difference is worth keeping.
        editorSupport: .uploadOnly,
        // `racket --version` prints "Welcome to Racket v8.10 [cs]."
        // and exits 0 (measured on 8.10). The generated tests invoke
        // the same binary, and — unlike C++ — nothing is produced to
        // execute afterwards, so probe and invocation genuinely cannot
        // skew here.
        interpreterProbe: .init(command: "racket", versionArguments: ["--version"]),
        // `(require "student.rkt")` is a FILE path, resolved relative
        // to the requiring module — R's shape, not Python's. Nothing
        // is name-addressable and no search-path variable applies.
        //
        // The test does not actually `require` the submission (an HtDP
        // module exports nothing; see the enum case), but the
        // resolution MECHANISM this field describes is still file
        // reading — `dynamic-require` takes a `(file ...)` path too.
        moduleResolution: .fileRead,
        // Racket resolves a relative module path against the enclosing
        // module's own directory, so a test and the submission beside
        // it find each other with nothing set. Verified, not assumed —
        // this is the field the Octave run proved you cannot reason
        // your way to.
        workingDirectoryIsOnDefaultSearchPath: true,
        // Interpreted: the runner hands a file to `racket`. Nothing is
        // built, so there is no second capability to prove.
        capabilityRequiresExecutableOutput: false
    )
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
    /// achieve anything. Python is the case that proves the second is required
    /// — by-name resolution whose cwd is genuinely off the driver's path.
    /// (Octave was predicted to be a second such case and measured not to be:
    /// its default load path opens with `.`, so nothing needs setting.)
    public var supportFilesPathEnvironmentVariable: String? {
        switch descriptor.moduleResolution {
        case .fileRead:
            return nil
        case .byName(let searchPathVariable, _):
            return descriptor.workingDirectoryIsOnDefaultSearchPath ? nil : searchPathVariable
        }
    }
}
