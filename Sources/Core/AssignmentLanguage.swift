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

    /// The language a graded-script filename extension implies, or nil for an
    /// extension that carries no language signal (`sh`, data files, …).
    /// Case-insensitive, so `.R` and `.r` both answer `.r`.
    public init?(scriptExtension: String) {
        let lowered = scriptExtension.lowercased()
        guard
            let match = AssignmentLanguage.allCases.first(where: {
                $0.scriptExtensions.contains(lowered)
            })
        else { return nil }
        self = match
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
    static func gradedScriptLanguage(in manifest: TestProperties) -> AssignmentLanguage? {
        allCases.first { language in
            manifest.testSuites.contains {
                AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension)
                    == language
            }
        }
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

    /// Resolve the language from the manifest and (optionally) the notebook
    /// kernel. Precedence:
    ///   0. the manifest's recorded `language`, when it has one — an explicit
    ///      answer always beats sniffing, and it is what lets a suite made up
    ///      only of pattern families (no graded script to find) keep its
    ///      language;
    ///   1. any graded test script (`.R` → `.r`, `.lua` → `.lua`, `.py` →
    ///      `.python`), in `allCases` order — the graded suite is the strongest
    ///      signal, it's what actually runs;
    ///   2. else a notebook kernel whose `kernelspec.name` / `language_info.name`
    ///      is in some language's `notebookKernelNames`;
    ///   3. else **nil** — no signal says this assignment has a language.
    ///
    /// nil is a legal, supported answer, NOT an error: an assignment whose suite
    /// is plain `.sh` scripts is the system's original mode and has no language
    /// in the `AssignmentLanguage` sense. It means "no language-specific
    /// machinery applies" — refuse only at the operations that genuinely need a
    /// language (rendering a literal, evaluating a per-student `=` expression,
    /// generating a pattern family, picking an editor kernel).
    ///
    /// This used to answer `.python` instead of nil, which made "this is
    /// Python" and "nothing here says anything" indistinguishable. Every silent
    /// misroute in this area descended from that, Lua shipping green while
    /// resolving to Python among them.
    ///
    /// Deliberately not public (docs/language-handling-review.md §3): the
    /// defaulted parameters made `resolve(manifest: props)` an easy spelling
    /// that silently skips the notebook sniff — the bug class the
    /// `resolve(for:manifest:)` server wrapper exists to prevent. External
    /// callers state their notebook source explicitly: `resolve(manifest:notebookData:)`
    /// here, or the `APITestSetup` wrapper in `AssignmentLanguageResolution.swift`.
    static func resolve(
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

    /// True when a notebook's `metadata` marks it as R: `kernelspec.name` is in
    /// `rKernelNames`, or `language_info.name` is `"r"`.
    ///
    /// The one implementation of that two-step sniff. `rederive`, the worker's
    /// submission routing (`submissionIsRNotebook`) and its notebook→source
    /// extraction (`extractNotebooksToCode`) all call through here, so the
    /// alias list lives in exactly one place.
    public static func isRNotebookMetadata(_ metadata: [String: Any]) -> Bool {
        fromNotebookMetadata(metadata) == .r
    }

    /// `isRNotebookMetadata(_:)` for a parsed notebook object. A notebook with
    /// no `metadata` has nothing to sniff and is not R — matching what every
    /// caller already did on a missing/unparseable metadata dictionary.
    public static func isRNotebook(_ notebook: [String: Any]) -> Bool {
        guard let metadata = notebook["metadata"] as? [String: Any] else { return false }
        return isRNotebookMetadata(metadata)
    }

    /// Resolve including the assignment's starter notebook, read straight from
    /// `.ipynb` bytes.
    ///
    /// This is the only signal a *brand-new* notebook assignment has. Its suite
    /// is still empty and nothing has recorded a language yet, so
    /// `resolve(manifest:)` alone answers nil — and used to answer `.python`,
    /// which meant an instructor's first R `=` expression was evaluated by
    /// `python3` and rejected with a Python `SyntaxError`, before any `.R`
    /// script existed to give the game away.
    ///
    /// Returns nil when neither the manifest nor the notebook names a language;
    /// see `resolve(manifest:notebookKernelName:notebookLanguageInfoName:)` for
    /// why that is a legal answer rather than a failure.
    /// `notebookData` is an autoclosure because only step 2 of the precedence
    /// needs it: a recorded language or an `.R` script in the suite both
    /// outrank the kernelspec, so callers on hot paths (the worker job payload,
    /// every suite save) don't pay to read the notebook off disk to be told
    /// something the manifest already knew.
    public static func resolve(
        manifest: TestProperties,
        notebookData: @autoclosure () -> Data?
    ) -> AssignmentLanguage? {
        // The kernelspec is consulted only when the manifest said nothing at
        // all — a manifest answer of any kind outranks it.
        if let manifestOnly = resolve(manifest: manifest) { return manifestOnly }
        guard let data = notebookData(),
            let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let metadata = notebook["metadata"] as? [String: Any]
        else {
            return nil
        }
        return resolve(
            manifest: manifest,
            notebookKernelName: (metadata["kernelspec"] as? [String: Any])?["name"] as? String,
            notebookLanguageInfoName: (metadata["language_info"] as? [String: Any])?["name"]
                as? String
        )
    }

    /// Re-derive the language from scratch, **ignoring any recorded
    /// `manifest.language`**.
    ///
    /// `resolve` treats a recorded language as an authoritative answer (step 0),
    /// which is what a stable render needs — but it also makes the recorded value
    /// a one-way door: a Python assignment cloned and converted to R keeps
    /// rendering `.py` forever, because the sticky `.python` outranks the new R
    /// notebook. When the starter notebook is *replaced* the recorded value is a
    /// stale memo, not a declaration, so re-derivation must skip it. Precedence
    /// is otherwise identical to `resolve`: a graded script wins (`.R` → `.r`,
    /// `.lua` → `.lua`, `.py` → `.python`), else the notebook's own kernel via
    /// `fromNotebookMetadata`, else nil.
    public static func rederive(
        manifest: TestProperties,
        notebookData: @autoclosure () -> Data?
    ) -> AssignmentLanguage? {
        if let scriptLanguage = gradedScriptLanguage(in: manifest) { return scriptLanguage }
        guard let data = notebookData(),
            let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let metadata = notebook["metadata"] as? [String: Any]
        else {
            return nil
        }
        // `fromNotebookMetadata`, not `isRNotebookMetadata(…) ? .r : .python`: the
        // ternary compiles forever and routes every non-R notebook to Python, so
        // a Lua notebook re-derived as Python. The general form returns the
        // language it recognised, or nil when it recognised none.
        return fromNotebookMetadata(metadata)
    }
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
            "\(lineCommentLeader) Auto-generated per-student grading inputs (issue #461). Do not edit."
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

    /// This language's line-comment leader.
    ///
    /// Lua's is why this is a per-language answer and not one shared `#`. `#` is
    /// not a Lua comment — but a Lua chunk whose FIRST line starts with `#` has
    /// that line skipped outright, a shebang accommodation. So a `#` header
    /// parsed, the round-trip test passed, and the file was one edit away from
    /// breaking: move the header down a line, or put anything above it, and the
    /// whole inputs file becomes a syntax error that surfaces as every
    /// per-student value silently reading as missing. Racket fails the same way
    /// but louder — `#` there begins a reader macro (`#t`, `#lang`, `#(`), so a
    /// `#`-led header is a read error rather than an ignored line.
    ///
    /// Hoisted out of `renderInputsFile`, which was its only caller until the
    /// runtime-helper drift guard needed the same fact to tell a language's
    /// prose from its code. A second hand-written table would have been a second
    /// chance to give Lua a `#`.
    public var lineCommentLeader: String {
        switch self {
        case .lua: return "--"
        case .octave: return "%"
        case .cpp: return "//"
        case .racket: return ";"
        case .python, .r: return "#"
        }
    }

    /// The name this language advertises itself under in a runner's
    /// `languageVersions`, and the token an assignment's required-languages
    /// list is matched against. The raw value, so the two halves cannot drift.
    public var capabilityName: String { rawValue }

}
