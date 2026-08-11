// Core/AssignmentLanguage.swift
//
// The programming language an assignment is authored + graded in, made
// first-class so every language-specific path (literal rendering, per-student
// expression evaluation, `_ck_inputs.*` value delivery, notebook substitution)
// dispatches on one resolved value instead of re-sniffing file extensions or
// notebook kernelspecs at each call site.

import Foundation

public enum AssignmentLanguage: String, Codable, Sendable, CaseIterable {
    case python
    case r
    case lua
    case octave
    /// Compiled C++ — the first language with NO editor kernel
    /// (`EditorSupport.uploadOnly`): assignments are upload-only and grade on
    /// the native worker exclusively, because the browser cannot run the
    /// course's real g++ toolchain and grading a different compiler than the
    /// course teaches would be a pedagogy defect (docs/cpp-support.md).
    /// Generated tests are `.sh` wrappers that compile a single translation
    /// unit (`test_runtime.hpp` + the student's file) with g++ and run the
    /// binary under the ordinary shell-script contract — no per-language
    /// build strategy enters Swift.
    case cpp

    /// Racket — the second upload-only language, and the first that is
    /// upload-only WITHOUT being compiled.
    ///
    /// No xeus kernel exists on `emscripten-forge-4x` (measured against the
    /// channel's repodata, which carries cpp/haskell/javascript/lfortran/lua/
    /// ocaml/octave/python/r/sqlite and no Scheme family at all), so
    /// `EditorSupport.uploadOnly` — but for a different reason than C++. C++
    /// has no kernel because grading a different compiler than the course
    /// teaches is a pedagogy defect; Racket has none because nobody has built
    /// one. That distinction matters if a kernel ever appears: Racket's
    /// upload-only answer is contingent, C++'s is a decision.
    ///
    /// It is otherwise the CHEAPEST language here: interpreted, so
    /// `racket file.rkt` needs no build step and no `.sh` wrapper; and
    /// dynamically typed, so `JSONValue` renders without C++'s refusal table.
    ///
    /// The one thing measurement changed: a generated test cannot `require`
    /// the student's module, because an HtDP teaching-language module
    /// (`#lang htdp/bsl`, what CS 135/115 write) exports nothing. Tests load
    /// the submission with `dynamic-require` + `module->namespace` and
    /// evaluate a CALL FORM rather than a bare identifier — Beginner Student
    /// Language rejects a function reference that is not in operator position.
    /// One mechanism serves `#lang htdp/bsl` and `#lang racket` alike, so a
    /// generated test is byte-identical across the CS 135 and CS 136 dialects.
    case racket

    /// Kernelspec `name` values that mark a Python notebook. `xpython` is the
    /// vendored xeus-python kernel; `python3` is what classic Jupyter writes and
    /// `python` is what `language_info.name` reports.
    ///
    /// Python used to have NO aliases and no positive script match, because it
    /// was the resolution default — which made "this is Python" and "we could
    /// not tell" the same answer, and every silent-misroute bug in this area
    /// descended from that. Resolution is Optional now (see `resolve`), so
    /// Python resolves positively like any other language and "we could not
    /// tell" is `nil`.
    public static let pythonKernelNames: Set<String> = ["python", "python3", "xpython"]

    /// Kernelspec `name` values (and `language_info.name`) that mark an R
    /// notebook. The single source of truth for the sniff: every Swift consumer
    /// reads it through `isRNotebookMetadata(_:)` rather than re-listing the
    /// aliases, so teaching Chickadee a new R kernel is one edit here.
    ///
    /// The browser runner cannot import Swift, so `Public/browser-runner.js`
    /// carries a generated copy in `R_KERNEL_NAMES`, written into a fenced
    /// block by `scripts/generate-js-constants.sh` from this declaration.
    /// After editing this set, run that script; the CI format-lint job fails
    /// while the generated copy is stale.
    public static let rKernelNames: Set<String> = ["ir", "r", "webr", "xr"]

    /// Kernelspec `name` values that mark a Lua notebook. `xlua` is the
    /// vendored xeus-lua kernel; `lua` is what `language_info.name` reports.
    ///
    /// Carried in the same generated block as `rKernelNames` in
    /// `Public/browser-runner.js` — after editing either, run
    /// `scripts/generate-js-constants.sh`.
    public static let luaKernelNames: Set<String> = ["xlua", "lua"]

    /// Kernelspec `name` values that mark an Octave notebook. `xoctave` is the
    /// vendored xeus-octave kernel; `octave` is its kernelspec `language`
    /// (lowercased) and what `language_info.name` reports.
    ///
    /// Deliberately does NOT claim `matlab`: a notebook authored against a
    /// MATLAB kernel is usually valid Octave, but claiming it would silently
    /// reroute any MATLAB-kernel notebook an instructor uploads, and that is a
    /// decision to take knowingly rather than inherit from an alias list.
    ///
    /// Carried in the same generated block as the others in
    /// `Public/browser-runner.js` — after editing, run
    /// `scripts/generate-js-constants.sh`.
    public static let octaveKernelNames: Set<String> = ["xoctave", "octave"]

    /// See `LanguageDescriptor.notebookKernelNames`.
    public var notebookKernelNames: Set<String> { descriptor.notebookKernelNames }

    /// The language a notebook's `metadata` positively declares, or nil when it
    /// declares nothing recognisable (in which case the caller falls back to
    /// `default`). Checks `kernelspec.name` first, then `language_info.name`.
    ///
    /// The ONE implementation of the sniff. `isRNotebookMetadata` is a thin
    /// equality on top of it rather than a second copy, so a new language is a
    /// `notebookKernelNames` arm and nothing else.
    public static func fromNotebookMetadata(_ metadata: [String: Any]) -> AssignmentLanguage? {
        if let kernel = (metadata["kernelspec"] as? [String: Any])?["name"] as? String {
            let lowered = kernel.lowercased()
            if let match = allCases.first(where: { $0.notebookKernelNames.contains(lowered) }) {
                return match
            }
        }
        if let info = (metadata["language_info"] as? [String: Any])?["name"] as? String {
            let lowered = info.lowercased()
            if let match = allCases.first(where: { $0.notebookKernelNames.contains(lowered) }) {
                return match
            }
        }
        return nil
    }

    /// See `LanguageDescriptor.scriptExtensions`.
    public var scriptExtensions: Set<String> { descriptor.scriptExtensions }

    /// Every graded-script extension, mapped to the language that claims it.
    ///
    /// BUILT FROM `allCases`, so it is discovered rather than enumerated and a
    /// seventh language needs no edit. Extensions are disjoint across languages
    /// — asserted by `LanguageConformanceMatrixTests
    /// .scriptExtensionsAreDisjointAcrossLanguages` — so the flattening is
    /// lossless; a collision would silently drop one claim, which is why that
    /// test is the load-bearing half of this.
    ///
    /// A stored map because the lookup below is called in loops (the resolution
    /// walk, the worker's submission staging), and a linear scan over
    /// `allCases` had to touch every language's `scriptExtensions` to answer a
    /// MISS — which is the common case, since `.sh`, data files and READMEs all
    /// land here.
    /// The `allCases` position is carried alongside the language so the
    /// resolution walk can rank what it finds with an `Int` compare. It cannot
    /// use `==` or a `Set` for that: `AssignmentLanguage` has a `String` raw
    /// value, so its synthesized `Hashable`/`Equatable` go through `rawValue`,
    /// and every comparison hashes a string.
    private static let languageByScriptExtension: [String: (language: AssignmentLanguage, rank: Int)] =
        allCases.enumerated().reduce(into: [:]) { table, pair in
            for ext in pair.element.scriptExtensions { table[ext] = (pair.element, pair.offset) }
        }

    /// The language a graded-script filename extension implies, or nil for an
    /// extension that carries no language signal (`sh`, data files, …).
    /// Case-insensitive, so `.R` and `.r` both answer `.r`.
    public init?(scriptExtension: String) {
        guard let match = AssignmentLanguage.languageByScriptExtension[scriptExtension.lowercased()]
        else { return nil }
        self = match.language
    }

    /// The lowercased extension of a suite entry's script path, without
    /// building a `URL` to get it.
    ///
    /// `URL(fileURLWithPath:).pathExtension` is what this replaced, and it is
    /// the single most expensive thing that was on this path: **4.5 µs per
    /// call**, measured, on Linux Foundation. `gradedScriptLanguage` called it
    /// once per suite entry per language, so a 40-entry suite paid it 240
    /// times — 1.07 ms of the 1.27 ms that walk cost.
    ///
    /// Scanned over UTF-8, not `Character`s: `String.lastIndex(of:)` does
    /// grapheme-cluster breaking over the whole path, which was ~350 ns per
    /// entry on its own. Script names are ASCII filenames, so the byte scan is
    /// behaviour-identical and allocation-free until the extension itself.
    ///
    /// Agrees with `URL.pathExtension` on every name whose base does not begin
    /// with a dot — asserted by
    /// `AssignmentLanguageTests.scriptExtensionScanAgreesWithFoundation`, a
    /// differential over generated names rather than a list of examples. That
    /// distinction earned itself immediately: the first version applied the
    /// dotfile rule to the LAST dot rather than the FIRST character of the base
    /// name, so `..R` claimed an R assignment. A hand-picked example list would
    /// have contained `.gitignore`, passed, and shipped it.
    ///
    /// ON DOTFILES IT DELIBERATELY DIVERGES, because Foundation's answer there
    /// is not a rule anyone would want to reproduce — measured on Linux
    /// Foundation:
    ///
    /// | name | `URL.pathExtension` | here |
    /// |---|---|---|
    /// | `.R`, `.gitignore` | `""` | `""` |
    /// | `..R` | `""` | `""` |
    /// | `...R` | `""` | `""` |
    /// | `....R` | **`"R"`** | `""` |
    ///
    /// Four leading dots claim an extension where two and three do not. This
    /// uses the classic rule instead — a base name beginning with `.` is a
    /// dotfile and has no extension — so the only names that answer differently
    /// are hidden files, and they answer *nil language* rather than a wrong
    /// one. That is the safe direction: nil means "no language-specific
    /// machinery applies", which is a supported state (a plain `.sh` suite),
    /// while a wrong language renders generated tests the suite can never run.
    /// `FilenameSafety` permits such a name (it rejects only `.` and `..`
    /// exactly), so this is a reachable input and not a can't-happen.
    private static func scriptExtension(ofPath path: String) -> String {
        let utf8 = path.utf8
        var baseStart = utf8.startIndex
        var lastDot: String.Index?
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let next = utf8.index(after: index)
            switch utf8[index] {
            case UInt8(ascii: "/"): baseStart = next; lastDot = nil
            case UInt8(ascii: "."): lastDot = index
            default: break
            }
            index = next
        }
        // A base name beginning with a dot is a dotfile, whatever follows it:
        // `.gitignore` and `..R` alike have no extension.
        guard baseStart != utf8.endIndex, utf8[baseStart] != UInt8(ascii: "."),
            let dot = lastDot
        else { return "" }
        // Sliced off the original string by the index the scan already has —
        // no byte copy, and `lowercased()` is the same full-Unicode folding
        // `init?(scriptExtension:)` has always applied, so `.R` and `.r` still
        // answer alike. `.` is ASCII, so the index after it is a Character
        // boundary and the slice is valid.
        return path[utf8.index(after: dot)...].lowercased()
    }

    /// The language whose graded script appears in `manifest`'s suite, in
    /// `allCases` order (so a mixed R+Lua suite resolves R-first, matching
    /// `manifestOwningLanguage`), or nil when the suite carries no
    /// language-bearing script at all — a suite of plain `.sh` scripts, or an
    /// empty one.
    ///
    /// The strongest resolution signal — the graded suite is what actually runs
    /// — and the single implementation of it, so `resolve` and `rederive` cannot
    /// disagree about which language a `.lua`/`.R` script implies.
    ///
    /// Python is matched positively here like every other language. It used to
    /// be skipped (`language != .default`) so that it was only ever reached by
    /// falling through, which meant a `.py` suite and a suite with no language
    /// at all produced the same answer. `.sh`-only suites are the case that
    /// distinction was really protecting, and nil now says so directly.
    /// ONE PASS over the suite, then `allCases` order applied to what was
    /// found. It used to be the other way round — `allCases.first { suites
    /// .contains { … } }` — which walked the suite once per language and, on a
    /// suite carrying no language at all, walked all of it six times over. That
    /// case is not exotic: a plain `.sh` suite is the system's original mode
    /// and a supported one, and it was the WORST case, 1.27 ms for 40 entries
    /// on the worker claim path. The `allCases`-order tie-break is preserved
    /// exactly (a mixed R+Lua suite still resolves R-first); it is applied to
    /// the set of languages present rather than used to drive the search.
    static func gradedScriptLanguage(in manifest: TestProperties) -> AssignmentLanguage? {
        var best: (language: AssignmentLanguage, rank: Int)?
        for entry in manifest.testSuites {
            guard let found = languageByScriptExtension[scriptExtension(ofPath: entry.script)]
            else { continue }
            if found.rank < (best?.rank ?? Int.max) { best = found }
            // Nothing can outrank the first case, so a suite that contains it
            // stops here rather than walking the rest.
            if found.rank == 0 { break }
        }
        return best?.language
    }

    /// Every language an interpreter must exist for before this manifest can be
    /// graded: the declared one, plus every language its suite's scripts are
    /// written in.
    ///
    /// These are two different questions and only together do they answer "can
    /// this runner grade this job?". The declaration says what Chickadee
    /// GENERATES; the suite says what the runner will actually be asked to
    /// execute, and a suite may legitimately mix — the runner classifies each
    /// script independently (`classifyScriptInterpreter`) and stages every
    /// language's `test_runtime.*` into the workspace, so a hand-written `.R`
    /// helper inside a Python assignment runs under `Rscript` and always has.
    ///
    /// Asking only the declaration is how a `.R` helper in a Python assignment
    /// could be claimed by an R-less runner and die at `exit 127` in front of a
    /// student — the exact failure `RunnerLanguageGate` exists to prevent, for a
    /// shape it could not see.
    ///
    /// Extensions that name no assignment language contribute nothing, which is
    /// what keeps the original mode claimable by anyone: `.sh` carries no
    /// language signal (deliberately — C++'s generated cases ARE `.sh`
    /// wrappers), and neither do the other interpreters the runner can dispatch
    /// but Chickadee cannot author in, like `.rb` or `.js`. A plain `.sh` suite
    /// on an assignment declaring nothing therefore returns the empty set.
    public static func languagesRequiredToGrade(manifest: TestProperties) -> Set<AssignmentLanguage> {
        var required: Set<AssignmentLanguage> = []
        if let declared = manifest.language { required.insert(declared) }
        for entry in manifest.testSuites {
            guard let found = languageByScriptExtension[scriptExtension(ofPath: entry.script)]
            else { continue }
            required.insert(found.language)
        }
        return required
    }

    /// The language a notebook kernel name (`kernelspec.name` then
    /// `language_info.name`) declares, or nil when neither is recognised. The
    /// string-argument form of `fromNotebookMetadata`, matched against every
    /// language's `notebookKernelNames` — including Python's, which is why a
    /// Python notebook now resolves positively rather than by fallthrough.
    private static func languageFromKernelNames(
        _ kernelName: String?, _ languageInfoName: String?
    ) -> AssignmentLanguage? {
        for candidate in [kernelName, languageInfoName] {
            if let lowered = candidate?.lowercased(),
                let match = allCases.first(where: { $0.notebookKernelNames.contains(lowered) })
            {
                return match
            }
        }
        return nil
    }

    /// The language this assignment DECLARES, or nil when it declares none.
    ///
    /// NO SNIFFING. This used to fall back to a graded script's extension and
    /// then to the starter notebook's kernel, which is how "the author chose
    /// Python" and "we guessed Python from a `.py` file" became the same
    /// answer. Every silent misroute in this arc descended from that: a Lua
    /// assignment resolving to Python, an R author's first `=` expression sent
    /// to `python3`, a browser writing `_ck_inputs.py` for an R runtime.
    ///
    /// Declaration is now a requirement, not a hint. Every door that creates an
    /// assignment answers the question — the web create page's `required`
    /// select (with an explicit "None"), MCP `create_assignment`'s required
    /// `language`, the REST zip upload, and course-bundle import — and
    /// `BackfillDeclaredLanguage` answered it for everything that predates the
    /// rule. So a nil here means "the author says this has no language", which
    /// is a real and supported state (a suite of plain `.sh` scripts), and NOT
    /// "nobody has been asked".
    ///
    /// Derivation still happens, exactly once, at the moment content arrives
    /// without an answer — see `derivedDeclaration`. It is a boundary step, not
    /// a resolution strategy.
    public static func resolve(manifest: TestProperties) -> AssignmentLanguage? {
        manifest.language
    }

    /// Derive a language for content that arrives WITHOUT a declaration, so it
    /// can be recorded once and never guessed again.
    ///
    /// THE ONLY REMAINING SNIFF, and it is deliberately not called `resolve`.
    /// Three callers, all of them boundaries where content enters the system
    /// with no author answer attached: the REST zip upload, course-bundle
    /// import, and the one-time backfill. Each records the result immediately,
    /// so the guess is made once and becomes a declaration.
    ///
    /// Precedence is the old resolution order, preserved so that what gets
    /// recorded matches what the system used to compute on the fly: a graded
    /// script's extension (in `allCases` order, so a mixed suite resolves
    /// deterministically), then the starter notebook's kernel, then nil.
    public static func derivedDeclaration(
        manifest: TestProperties,
        notebookKernelName: String? = nil,
        notebookLanguageInfoName: String? = nil
    ) -> AssignmentLanguage? {
        if let recorded = manifest.language { return recorded }
        if let scriptLanguage = gradedScriptLanguage(in: manifest) { return scriptLanguage }
        return languageFromKernelNames(notebookKernelName, notebookLanguageInfoName)
    }
}

extension AssignmentLanguage {

    // `isRNotebookMetadata` / `isRNotebook` used to live here: two public
    // R-shaped booleans over `fromNotebookMetadata`, from when R was the only
    // non-Python language. Every caller they documented had already moved to
    // the general form — `rederive` calls `fromNotebookMetadata` directly, and
    // the worker's `submissionIsRNotebook` was generalised out of existence —
    // leaving the pair reachable from nothing but their own stale doc comment.
    // They are deleted rather than kept for convenience: a `Bool` return is the
    // `isRNotebook(nb) ? .r : .python` shape that type-checks forever and
    // routes every other language to Python, which is the compiler-invisible
    // trap `docs/adding-a-xeus-kernel.md` counts as its fifth. Leaving a
    // ready-made one in Core is an invitation to reintroduce it.

    /// Derive a declaration for content that arrives without one, reading the
    /// starter notebook's kernel straight from `.ipynb` bytes.
    ///
    /// The notebook is the ONLY signal a brand-new notebook assignment has: its
    /// suite is empty and no script names a language. This is what the REST zip
    /// upload and course-bundle import call to answer the question once, at the
    /// boundary, before recording the answer.
    ///
    /// `notebookData` is an autoclosure because a manifest that already names a
    /// language outranks the kernelspec, so a caller does not pay to read the
    /// notebook off disk to be told something the manifest already knew.
    ///
    /// This was `resolve(manifest:notebookData:)`, called on every read — the
    /// worker job payload, every suite save, every instructor page render. It is
    /// a one-shot now, and the rename is the point: nothing downstream derives a
    /// language any more, it reads the declared one.
    public static func derivedDeclaration(
        manifest: TestProperties,
        notebookData: @autoclosure () -> Data?
    ) -> AssignmentLanguage? {
        if let fromManifest = derivedDeclaration(manifest: manifest) { return fromManifest }
        guard let data = notebookData(),
            let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let metadata = notebook["metadata"] as? [String: Any]
        else {
            return nil
        }
        return derivedDeclaration(
            manifest: manifest,
            notebookKernelName: (metadata["kernelspec"] as? [String: Any])?["name"] as? String,
            notebookLanguageInfoName: (metadata["language_info"] as? [String: Any])?["name"]
                as? String
        )
    }

    // `rederive(manifest:notebookData:)` used to live here: re-derivation that
    // ignored the recorded language, so that replacing a starter notebook
    // changed the assignment's language under the author.
    //
    // It existed because the recorded value was a MEMO — "what resolution last
    // computed" — and a memo goes stale when the content it summarised is
    // replaced. A declaration does not. An author who converts a Python
    // assignment to R changes the language in the dropdown that already exists
    // for exactly that purpose; a notebook upload no longer changes it silently
    // underneath them.
    //
    // Its one caller, `manifestWithRederivedLanguage`, is gone with it.
}

// MARK: - Per-language rendering / delivery strategy
//
// A closed 2-case enum owns its own language-specific behavior (cleaner than a
// protocol + 2 conformances). Every site that used to hardcode Python — literal
// rendering, the `_ck_inputs.*` file, the expression driver — dispatches here so
// adding a third language later is one `case`.

extension AssignmentLanguage {

    /// Render a JSON value as a source literal in this language.
    public func literal(_ value: JSONValue) -> String {
        switch self {
        case .python: return value.pythonLiteral
        case .r: return value.rLiteral
        case .lua: return value.luaLiteral
        case .octave: return value.octaveLiteral
        case .cpp: return value.cppLiteral
        case .racket: return value.racketLiteral
        }
    }

    /// Filename of the per-student grading-inputs file the worker materializes.
    /// See `LanguageDescriptor.inputsFileName`.
    public var inputsFileName: String { descriptor.inputsFileName }

    /// Extension for scripts Chickadee generates (pattern-family cases,
    /// notebook checks). `.py` for Python — unchanged, so every existing
    /// generated filename, `spec_hash` and `TestSetupCache` key is stable.
    /// See `LanguageDescriptor.generatedScriptExtension`.
    public var generatedScriptExtension: String { descriptor.generatedScriptExtension }

    /// See `LanguageDescriptor.sourceFileExtension`.
    public var sourceFileExtension: String { descriptor.sourceFileExtension }

    /// See `LanguageDescriptor.lineCommentPrefix`.
    public var lineCommentPrefix: String { descriptor.lineCommentPrefix }

    /// Source the in-page auto-compute worker must prepend before it can report
    /// a value, or nil when the language needs nothing.
    ///
    /// Two jobs, both already solved elsewhere and therefore NOT re-solved here:
    /// turning a value into round-trippable text (Lua and Octave have no
    /// built-in form; `deparse` and `repr` are builtins for R and Python), and
    /// escaping that text into the JSON payload the worker prints behind its
    /// per-run nonce.
    ///
    /// Every piece of this is an existing Core constant, shared with the server
    /// driver and the grading runtime, so the in-page and server paths cannot
    /// disagree about what a value looks like.
    ///
    /// A NOTE ON THE ENCODING, because I got this wrong once. I first planned a
    /// nonce-framed plaintext payload instead of JSON, to avoid pushing a string
    /// escaper into three languages — and the tree does carry two rival R
    /// encoders (a `gsub` one in the grading runtime, and the char-by-char one
    /// below, written because the first trips over replacement-string backslash
    /// rules). But the escapers already EXIST for all three languages as
    /// constants, so framing bought nothing and cost a second payload encoding
    /// beside Python's, with a second parser to match. The eval protocol stays
    /// exactly the one `python-eval-worker.js` speaks.
    public var autoComputeRuntimeSource: String? {
        switch self {
        case .python:
            // `repr` serializes and the snippet builds its payload with
            // Python's own `json` module. Nothing to prepend.
            return nil
        case .r:
            // `deparse` serializes; only the escaper is needed.
            return RPersonalizationRuntime.chickadeeJSONStringRSource
        case .lua:
            // Four pieces, and the order matters. The sentinel comes first: a
            // rendered argument may mention `chickadee.NULL`, and the eval
            // worker loads no `test_runtime` to bind it. The exports come last,
            // because they are the only place the two `local` declarations
            // above are still in scope.
            //
            // `Tools/browser-grading-smoke` rebuilds this list from the same
            // constants; `LuaAutoComputeRuntimeTests` fails if a fifth piece is
            // added here without updating it.
            return [
                LuaPersonalizationRuntime.chickadeeNullTableLuaSource,
                LuaPersonalizationRuntime.chickadeeSerializeLuaSource,
                LuaPersonalizationRuntime.chickadeeJSONStringLuaSource,
                LuaPersonalizationRuntime.chickadeeAutoComputeExportsLuaSource,
            ].joined(separator: "\n\n")
        case .octave:
            return OctavePersonalizationRuntime.chickadeeSerializeOctaveSource + "\n\n"
                + OctavePersonalizationRuntime.chickadeeEscapeStringOctaveSource
        case .cpp, .racket:
            // No kernel, so no in-page worker to prepend anything to.
            return nil
        }
    }

    /// Body of the per-student grading-inputs file. `values` maps each input
    /// name to its already-rendered literal *in this language* (Python literal
    /// for `.python`, R literal for `.r`). Keys are emitted in sorted order for
    /// deterministic output.
    ///
    /// The `.python` form is byte-for-byte identical to the historical
    /// `_ck_inputs.py` writer, so existing assignments are unchanged. The `.r`
    /// form binds `.ck_inputs` (R forbids a leading-underscore identifier, so the
    /// variable can't be `_ck`) and omits the trailing comma R's `list()` rejects.
    public func renderInputsFile(_ values: [String: String]) -> String {
        let header =
            "\(lineCommentPrefix) Auto-generated per-student grading inputs (issue #461). Do not edit."
        let keys = values.keys.sorted()
        switch self {
        case .python:
            var lines = [header, "_ck = {"]
            for key in keys {
                lines.append("    \(JSONValue.string(key).pythonLiteral): \(values[key] ?? "None"),")
            }
            lines.append("}")
            return lines.joined(separator: "\n") + "\n"
        case .r:
            guard !keys.isEmpty else { return "\(header)\n.ck_inputs <- list()\n" }
            let assignments = keys.map { "    `\($0)` = \(values[$0] ?? "NULL")" }
            return "\(header)\n.ck_inputs <- list(\n"
                + assignments.joined(separator: ",\n")
                + "\n)\n"
        case .lua:
            // A chunk that RETURNS a table, because `chickadee.inputs()` reads
            // it with `loadfile` + `pcall` and keeps the returned value. Not a
            // global assignment: a Lua library that wrote globals would be a
            // surprise, and the runtime's own module is a table for the same
            // reason.
            //
            // A PURE DATA CHUNK — no `require`, no statements. The values may
            // mention `chickadee.NULL`, the sentinel `JSONValue.luaLiteral`
            // emits for a JSON null inside a table (Lua stores no `nil` in a
            // constructor, so a hole would silently eat an authored case's
            // positional alignment). That name is bound by the READER:
            // `chickadee.inputs()` loads this chunk with an environment
            // carrying the runtime, so the file itself stays dependency-free
            // and can be written into an empty directory.
            let assignments = keys.map {
                "    [\(JSONValue.string($0).luaLiteral)] = \(values[$0] ?? "nil")"
            }
            guard !keys.isEmpty else { return "\(header)\nreturn {}\n" }
            return "\(header)\nreturn {\n" + assignments.joined(separator: ",\n") + "\n}\n"
        case .octave:
            // Two parallel cell arrays rather than a struct or a Map literal:
            // input names are author-chosen strings, and Octave struct field
            // names must be identifiers, so a struct could not hold every
            // legal name. `chickadee.inputs()` evaluates this file's TEXT
            // (`eval(fileread(...))`) — never by its `_ck_inputs` script name
            // — and zips the two lists into a containers.Map, so the file
            // itself stays pure data that can be written into an empty
            // directory and read identically by both runners.
            let names = keys.map { JSONValue.string($0).octaveLiteral }
            let rendered = keys.map { values[$0] ?? "NA" }
            guard !keys.isEmpty else {
                return "\(header)\nck_input_names = {};\nck_input_values = {};\n"
            }
            return "\(header)\n"
                + "ck_input_names = { " + names.joined(separator: ", ") + " };\n"
                + "ck_input_values = { " + rendered.joined(separator: ", ") + " };\n"
        case .cpp:
            // A HEADER, not a map: C++ needs a type per value, and a runtime
            // map would need one value type for all of them. Each input is its
            // own `inline const auto` in a namespace, so every value keeps the
            // natural type its literal has, and a generated test references
            // `ck_inputs::name` directly — a missing input is an undefined
            // identifier, which is the fail-closed check the other runtimes do
            // with isKey, only earlier and louder (at compile). Input names are
            // already validated as Python identifiers at authoring, which C++
            // accepts; C++'s extra reserved words are refused by the cpp
            // validator (`isValidCppIdentifier`).
            let definitions = keys.map { "inline const auto \($0) = \(values[$0] ?? "0");" }
            return "\(header)\n#pragma once\n#include <cmath>\n#include <limits>\n"
                + "#include <map>\n#include <string>\n#include <vector>\n"
                + "namespace ck_inputs {\n"
                + definitions.map { "    \($0)\n" }.joined()
                + "}\n"
        case .racket:
            // A MODULE that provides one hash, which is the shape Racket makes
            // natural and the one the runtime can read with `dynamic-require`.
            //
            // `#lang racket/base`, not `racket`: this file is loaded on every
            // generated test, and `racket/base` is the small language — the
            // full `racket` language pulls in a much larger set for values that
            // are, by construction, literals.
            //
            // Unlike the student's submission, this file is OURS, so it can
            // `provide` — the export problem that shapes everything else about
            // Racket support does not apply here.
            let entries = keys.map {
                "   \(JSONValue.string($0).racketLiteral) \(values[$0] ?? "'null")"
            }
            let body =
                keys.isEmpty
                ? "(define ck-inputs (hash))"
                : "(define ck-inputs\n  (hash\n" + entries.joined(separator: "\n") + "))"
            return "#lang racket/base\n\(header)\n(provide ck-inputs)\n\(body)\n"
        }
    }

    // MARK: - Language-specific facts that were boolean tests
    //
    // Each of these replaced an `if language == .python` / `== .r` at its call
    // site. The equality form compiles fine when a third case is added and
    // silently routes it down whichever branch it happens to fall — Python bytes
    // for a Julia assignment, R's error wording for a Julia ImportError. An
    // exhaustive switch here turns each of those into a compile error naming the
    // decision that has to be made. See docs/language-handling-review.md §4.

    /// The kernel facts, when this language has a vendored editor kernel —
    /// see `LanguageDescriptor.editorSupport`. Call sites that presuppose a
    /// kernel destructure this, so a kernel-less language forces an explicit
    /// answer there instead of inheriting a blank string.
    public var editorSupport: EditorSupport { descriptor.editorSupport }

    /// See `LanguageDescriptor.interpreterProbe`. Kept as a tuple here because
    /// every call site destructures it.
    public var interpreterProbe: (command: String, versionArguments: [String]) {
        (descriptor.interpreterProbe.command, descriptor.interpreterProbe.versionArguments)
    }

    /// See `LanguageDescriptor.displayName`.
    public var displayName: String { descriptor.displayName }

    // `lineCommentLeader` used to live here — a second switch answering exactly
    // what `LanguageDescriptor.lineCommentPrefix` answers. The two disagreed
    // about Octave (`%` here, `#` there) for as long as both existed, which
    // nothing caught because Octave accepts either. Callers now read
    // `lineCommentPrefix`; see its doc for why `%` is the surviving answer.

    /// The name this language advertises itself under in a runner's
    /// `languageVersions`, and the token an assignment's required-languages
    /// list is matched against. The raw value, so the two halves cannot drift.
    public var capabilityName: String { rawValue }

}
