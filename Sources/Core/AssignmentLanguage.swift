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

    /// What an assignment resolves to when nothing about it says otherwise.
    ///
    /// Named rather than written as `.python` at the comparison sites, because
    /// those sites are asking "did resolution fall back?" and not "is this
    /// Python?". The two questions have the same answer today and would diverge
    /// the moment a third language existed: `manifestOnly == .python` would
    /// stop consulting the notebook kernelspec for a Julia assignment that had
    /// resolved positively, which is the opposite of what that guard wants.
    public static let `default`: AssignmentLanguage = .python

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

    /// The non-default language whose graded script appears in `manifest`'s
    /// suite, in `allCases` order (so a mixed R+Lua suite resolves R-first,
    /// matching `manifestOwningLanguage`), or nil when only default-language
    /// (or no) graded scripts are present.
    ///
    /// The strongest resolution signal — the graded suite is what actually runs
    /// — and the single implementation of it, so `resolve` and `rederive` cannot
    /// disagree about which language a `.lua`/`.R` script implies. Python is the
    /// default and is never matched positively here; it is reached by falling
    /// through, which is what keeps every existing Python assignment unchanged.
    static func gradedScriptLanguage(in manifest: TestProperties) -> AssignmentLanguage? {
        allCases.first { language in
            language != .default
                && manifest.testSuites.contains {
                    AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension)
                        == language
                }
        }
    }

    /// The language a notebook kernel name (`kernelspec.name` then
    /// `language_info.name`) declares, or nil when neither is recognised. The
    /// string-argument form of `fromNotebookMetadata`, matched against every
    /// language's `notebookKernelNames` — Python's set is empty, so it is never
    /// matched positively and remains the fallthrough default.
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
    ///   1. any non-default graded test script (`.R` → `.r`, `.lua` → `.lua`),
    ///      in `allCases` order — the graded suite is the strongest signal,
    ///      it's what actually runs;
    ///   2. else a notebook kernel whose `kernelspec.name` / `language_info.name`
    ///      is in some language's `notebookKernelNames`;
    ///   3. else `.python` — the default, so every existing assignment resolves
    ///      exactly as today and its generated bytes stay byte-for-byte identical.
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
    ) -> AssignmentLanguage {
        if let recorded = manifest.language { return recorded }
        if let scriptLanguage = gradedScriptLanguage(in: manifest) { return scriptLanguage }
        return languageFromKernelNames(notebookKernelName, notebookLanguageInfoName) ?? .python
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
    /// `resolve(manifest:)` alone answers `.python` — which meant an
    /// instructor's first R `=` expression was evaluated by `python3` and
    /// rejected with a Python `SyntaxError`, before any `.R` script existed to
    /// give the game away.
    ///
    /// Falls back to the manifest-only resolution when the notebook is absent
    /// or unparseable, so nothing regresses for assignments without one.
    /// `notebookData` is an autoclosure because only step 2 of the precedence
    /// needs it: a recorded language or an `.R` script in the suite both
    /// outrank the kernelspec, so callers on hot paths (the worker job payload,
    /// every suite save) don't pay to read the notebook off disk to be told
    /// something the manifest already knew.
    public static func resolve(
        manifest: TestProperties,
        notebookData: @autoclosure () -> Data?
    ) -> AssignmentLanguage {
        let manifestOnly = resolve(manifest: manifest)
        // `== .default`, not `== .python`: the question is whether resolution
        // fell back, so that the kernelspec is only consulted when the manifest
        // said nothing. See the `default` declaration.
        guard manifest.language == nil, manifestOnly == .default else { return manifestOnly }
        guard let data = notebookData(),
            let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let metadata = notebook["metadata"] as? [String: Any]
        else {
            return manifestOnly
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
    /// is otherwise identical to `resolve`: a non-default graded script wins
    /// (`.R` → `.r`, `.lua` → `.lua`), else the notebook's own kernel via
    /// `fromNotebookMetadata`, else `.python`.
    public static func rederive(
        manifest: TestProperties,
        notebookData: @autoclosure () -> Data?
    ) -> AssignmentLanguage {
        if let scriptLanguage = gradedScriptLanguage(in: manifest) { return scriptLanguage }
        guard let data = notebookData(),
            let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let metadata = notebook["metadata"] as? [String: Any]
        else {
            return .python
        }
        // `fromNotebookMetadata`, not `isRNotebookMetadata(…) ? .r : .python`: the
        // ternary compiles forever and routes every non-R notebook to Python, so
        // a Lua notebook re-derived as Python. The general form returns the
        // language it recognised, or nil to mean "use the default".
        return fromNotebookMetadata(metadata) ?? .python
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
        // The comment leader is per-language, and Lua's is the reason this is
        // not one shared constant. `#` is not a Lua comment — but a Lua chunk
        // whose FIRST line starts with `#` has that line skipped outright, a
        // shebang accommodation. So a `#` header parsed, the round-trip test
        // passed, and the file was one edit away from breaking: move the header
        // down a line, or put anything above it, and the whole inputs file
        // becomes a syntax error that surfaces as every per-student value
        // silently reading as missing.
        let commentLeader: String
        switch self {
        case .lua: commentLeader = "--"
        case .octave: commentLeader = "%"
        case .python, .r: commentLeader = "#"
        }
        let header =
            "\(commentLeader) Auto-generated per-student grading inputs (issue #461). Do not edit."
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

    /// The env file a maintainer edits to add a package to this language's
    /// browser-grading kernel, named in the authoring rejection message.
    /// See `LanguageDescriptor.kernelEnvironmentFileName`.
    public var kernelEnvironmentFileName: String { descriptor.kernelEnvironmentFileName }

    /// How a missing dependency presents to a student at grade time, phrased for
    /// the same rejection message.
    /// See `LanguageDescriptor.missingDependencyFailureDescription`.
    public var missingDependencyFailureDescription: String {
        descriptor.missingDependencyFailureDescription
    }

    /// See `LanguageDescriptor.interpreterProbe`. Kept as a tuple here because
    /// every call site destructures it.
    public var interpreterProbe: (command: String, versionArguments: [String]) {
        (descriptor.interpreterProbe.command, descriptor.interpreterProbe.versionArguments)
    }

    /// See `LanguageDescriptor.displayName`.
    public var displayName: String { descriptor.displayName }

    /// The name this language advertises itself under in a runner's
    /// `languageVersions`, and the token an assignment's required-languages
    /// list is matched against. The raw value, so the two halves cannot drift.
    public var capabilityName: String { rawValue }

}
