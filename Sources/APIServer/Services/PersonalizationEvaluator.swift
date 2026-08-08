// APIServer/Services/PersonalizationEvaluator.swift
//
// Slice 2 of #461 — server-side evaluation of `PersonalizationExpression`
// rows with `seed` bound to the per-(student, assignment) hex seed.
//
// Each evaluation spawns the assignment's interpreter (`python3` or, for
// an R assignment, `Rscript`) against a tiny generated driver script that
// binds `seed`, every static `globalVariables` + section variable as
// module-level names, then evaluates each expression in declared order so
// later expressions can reference earlier ones.  Values are emitted as
// source literals (`repr(value)` in Python, `deparse(value)` in R) — drop-in
// literals that `NotebookSubstitution.apply` substitutes into `{{name}}`
// placeholders and that the worker writes into `_ck_inputs.{py,R}`. The
// language is chosen per assignment (`AssignmentLanguage`); the default is
// `.python`, so every existing caller is byte-for-byte unchanged.
//
// Trust model: instructor-authored Python on the instructor's own
// server.  Same risk profile as the validation-submission path that
// already executes instructor solution notebooks server-side.
// Sandboxed-exec parity with the worker (`sandbox-exec` /  `unshare`)
// is a future hardening; called out in the docs.

import Core
import Foundation

#if canImport(Glibc)
import Glibc
#endif

enum PersonalizationEvaluatorError: Error {
    case driverWriteFailed
    case spawnFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut
    case malformedOutput(stdout: String)
    case missingName(name: String, stdout: String)
}

/// Minimal counting semaphore for async contexts: `acquire` suspends (no
/// thread parked) once `width` slots are in use; `release` hands the slot to
/// the oldest waiter. Used to bound concurrent python3 evaluations (#1156).
actor AsyncCountingSemaphore {
    private let width: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(width: Int) {
        self.width = max(1, width)
    }

    func acquire() async {
        if inUse < width {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by release(), which transfers the slot without
        // decrementing `inUse`.
    }

    func release() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum PersonalizationEvaluator {

    /// Timeout (seconds) for a single evaluation subprocess.  Slice 2
    /// caps at 5 s — instructor expressions should be near-instant;
    /// anything slower is almost certainly a bug.
    static let defaultTimeoutSeconds: Int = 5

    /// Caps concurrent interpreter spawns server-wide (#1156): a deadline
    /// burst of first-opens on a personalized assignment previously forked
    /// one python3 per request with no ceiling. Excess evaluations suspend
    /// in the semaphore's queue; each is bounded by its own subprocess
    /// timeout once running.
    static let spawnGate = AsyncCountingSemaphore(
        width: max(2, ProcessInfo.processInfo.activeProcessorCount))

    /// Evaluates each `expressions` entry with `seed` and all listed
    /// static variables in scope.  Returns the rendered Python literal
    /// per expression name, suitable for dropping into a
    /// `NotebookSubstitution.apply` substitutions map.
    ///
    /// - `seedHex`: 64-char lowercase hex (the value persisted by
    ///   `AssignmentSeedStore`).  Sent to the subprocess as
    ///   `CHICKADEE_ASSIGNMENT_SEED` so the driver re-uses Phase 1's
    ///   wire contract.
    /// - `staticVariables`: every literal name in scope (globals +
    ///   section vars combined).  Order matters when names collide —
    ///   later entries win, matching the notebook substitution map's
    ///   "section overrides global" precedence.
    /// - `expressions`: evaluated in declared order, each seeing
    ///   `seed`, every entry in `staticVariables`, and every prior
    ///   expression's value as a Python global.
    static func evaluate(
        seedHex: String,
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFilesDirectory: String? = nil,
        language: AssignmentLanguage = .python,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws -> [String: String] {
        guard !expressions.isEmpty else { return [:] }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("chickadee_personalize_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Slice 5 of #461: when a support-files directory is provided, collect
        // every helper the driver should auto-load — Python `.py` module stems
        // (valid identifiers, `__init__` excluded) for the Python driver, or
        // `.R`/`.r` filenames for the R driver (which `source()`s them). The
        // solution notebook's code cells are extracted to `solution.py` /
        // `solution.R` and picked up here so an expression can call a
        // reference-solution function.
        let supportEntries = supportFileEntries(in: supportFilesDirectory, language: language, fm: fm)

        let plan = Self.driverPlan(
            language: language,
            staticVariables: staticVariables,
            expressions: expressions,
            supportEntries: supportEntries)
        let driverSource = plan.source
        let driverURL = tempDir.appendingPathComponent(plan.filename)
        let interpreter = plan.interpreter
        do {
            try driverSource.write(to: driverURL, atomically: true, encoding: .utf8)
        } catch {
            throw PersonalizationEvaluatorError.driverWriteFailed
        }

        // Subprocess cwd points at the support-files directory when supplied,
        // so `open("quotes.txt")` / `source("solution.R")` works for data files
        // and the auto-loaded helpers resolve. `PYTHONPATH` lets `import
        // helpers` resolve for Python only (R uses cwd-relative `source`). Falls
        // back to the isolated temp dir when no support dir is given (preserves
        // Slice 2 behaviour for callers that haven't been updated).
        var env: [String: String] = ["CHICKADEE_ASSIGNMENT_SEED": seedHex]
        let spawnCwd: URL
        if let supportFilesDirectory, fm.fileExists(atPath: supportFilesDirectory) {
            spawnCwd = URL(fileURLWithPath: supportFilesDirectory, isDirectory: true)
            if let pathVariable = language.supportFilesPathEnvironmentVariable {
                env[pathVariable] = supportFilesDirectory
            }
        } else {
            spawnCwd = tempDir
        }

        let stdout: String
        let stderr: String
        let exitCode: Int32
        await Self.spawnGate.acquire()
        do {
            (stdout, stderr, exitCode) = try await spawnAndCapture(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [interpreter, driverURL.path],
                cwd: spawnCwd,
                env: env,
                timeoutSeconds: timeoutSeconds
            )
            await Self.spawnGate.release()
        } catch PersonalizationEvaluatorError.timedOut {
            await Self.spawnGate.release()
            throw PersonalizationEvaluatorError.timedOut
        } catch {
            await Self.spawnGate.release()
            throw PersonalizationEvaluatorError.spawnFailed(String(describing: error))
        }

        if exitCode != 0 {
            throw PersonalizationEvaluatorError.nonZeroExit(code: exitCode, stderr: stderr)
        }

        // Parse the last non-empty line of stdout as JSON (mirrors the
        // runner's "last-line JSON" contract — instructor `print` calls
        // earlier in the driver don't break parsing).
        let lastLine =
            stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        guard let data = lastLine.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            throw PersonalizationEvaluatorError.malformedOutput(stdout: stdout)
        }

        // Defensive: every declared expression should have a value.
        for expr in expressions where obj[expr.name] == nil {
            throw PersonalizationEvaluatorError.missingName(name: expr.name, stdout: stdout)
        }
        return obj
    }

    // MARK: - Internals

    static func renderDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportModules: [String] = []
    ) -> String {
        var lines: [String] = [
            "# Auto-generated personalization driver.  Do not edit.",
            "import importlib, json, os",
            "",
            "seed = int(os.environ['CHICKADEE_ASSIGNMENT_SEED'], 16)",
            "",
        ]
        // Slice 5: auto-import every .py support module Chickadee can
        // see in the support-files dir.  Bind each module object as a
        // top-level Python name so expressions can call
        // `helpers.foo(...)` directly.  Broken modules silently
        // ImportError here — they surface as NameError at
        // expression-eval time if anything actually references them.
        if !supportModules.isEmpty {
            lines.append("# Auto-imported support modules (instructor-uploaded .py files +")
            lines.append("# the solution.ipynb code cells extracted into solution.py).")
            for name in supportModules {
                lines.append("try:")
                lines.append("    \(name) = importlib.import_module(\(stringLiteral(name)))")
                lines.append("except Exception:")
                lines.append("    pass  # surfaces as NameError at expression eval time if used")
            }
            lines.append("")
        }
        if !staticVariables.isEmpty {
            lines.append("# Static globals + section variables (in scope for expressions).")
            lines.append("# Explicit assignments shadow same-named auto-imports above.")
            for v in staticVariables {
                lines.append("\(v.name) = \(v.value.pythonLiteral)")
            }
            lines.append("")
        }
        lines.append("# Per-student expressions, evaluated in declared order.")
        for e in expressions {
            lines.append("\(e.name) = (\(e.expression))")
        }
        lines.append("")
        lines.append("# Emit one `repr(value)` per declared expression as a JSON map.")
        lines.append("_out = {}")
        for e in expressions {
            lines.append("_out[\(stringLiteral(e.name))] = repr(\(e.name))")
        }
        lines.append("print(json.dumps(_out))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The per-language driver: its source, the filename it is written under,
    /// and the command that runs it. Extracted from `evaluate` for length; the
    /// switch is the whole point (exhaustive — a new language cannot compile
    /// without answering how its expressions are evaluated).
    private static func driverPlan(
        language: AssignmentLanguage,
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportEntries: [String]
    ) -> (source: String, filename: String, interpreter: String) {
        let source: String
        let filename: String
        let interpreter: String
        switch language {
        case .python:
            source = renderDriverScript(
                staticVariables: staticVariables,
                expressions: expressions,
                supportModules: supportEntries
            )
            filename = "personalize_driver.py"
            interpreter = "python3"
        case .r:
            source = renderRDriverScript(
                staticVariables: staticVariables,
                expressions: expressions,
                supportFiles: supportEntries
            )
            filename = "personalize_driver.R"
            interpreter = "Rscript"
        case .racket:
            source = RacketPersonalizationDriver.render(
                staticVariables: staticVariables,
                expressions: expressions,
                supportFiles: supportEntries
            )
            filename = "personalize_driver.rkt"
            interpreter = "racket"
        case .lua:
            source = renderLuaDriverScript(
                staticVariables: staticVariables,
                expressions: expressions,
                supportFiles: supportEntries
            )
            filename = "personalize_driver.lua"
            interpreter = "lua"
        case .octave:
            source = renderOctaveDriverScript(
                staticVariables: staticVariables,
                expressions: expressions,
                supportFiles: supportEntries
            )
            filename = "personalize_driver.m"
            interpreter = "octave-cli"
        case .cpp:
            // No interpreter exists, so the driver is a shell script that
            // compiles a generated program with g++ and runs it (~0.3s per
            // evaluation, measured). One spawn shape for all five languages.
            source = CppPersonalizationDriver.renderDriverScript(
                staticVariables: staticVariables,
                expressions: expressions,
                supportFiles: supportEntries
            )
            filename = "personalize_driver.sh"
            interpreter = "sh"
        }
        return (source, filename, interpreter)
    }

    /// Discovers the support-file helpers the driver should auto-load, in the
    /// shape each language's driver expects: Python module stems for `.python`
    /// (valid identifiers, `__init__` excluded), `.R`/`.r` filenames for `.r`
    /// (the R driver `source()`s them). Returns a sorted list for deterministic
    /// driver bytes; empty when no support dir is given or it doesn't exist.
    private static func supportFileEntries(
        in supportFilesDirectory: String?,
        language: AssignmentLanguage,
        fm: FileManager
    ) -> [String] {
        guard let dir = supportFilesDirectory,
            fm.fileExists(atPath: dir),
            let entries = try? fm.contentsOfDirectory(atPath: dir)
        else {
            return []
        }
        switch language {
        case .python:
            return entries.compactMap { entry -> String? in
                guard entry.hasSuffix(".py") else { return nil }
                let stem = String(entry.dropLast(3))
                guard stem != "__init__", isValidPyIdent(stem) else { return nil }
                return stem
            }.sorted()
        case .r:
            return entries.filter { (($0 as NSString).pathExtension).lowercased() == "r" }.sorted()
        case .racket:
            // Loaded by FILE like R and Lua — the driver `dynamic-require`s each
            // helper and copies its bindings into the expression namespace, so
            // there is no module identifier to validate.
            return entries.filter { (($0 as NSString).pathExtension).lowercased() == "rkt" }.sorted()
        case .lua:
            // Like R, the driver loads these by FILE (`dofile`), not by module
            // name, so there is no identifier to validate — any `.lua` beside
            // the assignment is a candidate helper.
            return entries.filter { (($0 as NSString).pathExtension).lowercased() == "lua" }.sorted()
        case .octave:
            // Loaded by file too — the driver evaluates each helper's text
            // behind a `1;` script guard (the same trick the grading runtime's
            // load_student uses), so a one-function-per-file helper registers
            // under its own name rather than executing as a bare body.
            return entries.filter { (($0 as NSString).pathExtension).lowercased() == "m" }.sorted()
        case .cpp:
            // Included by FILE into the driver's single translation unit —
            // headers first, then sources (the extracted reference solution
            // arrives as `solution.cpp`), sorted within each group for
            // deterministic driver bytes.
            let lowered = entries.map { ($0, (($0 as NSString).pathExtension).lowercased()) }
            let headers = lowered.filter { $0.1 == "hpp" || $0.1 == "h" }.map(\.0).sorted()
            let sources = lowered.filter { $0.1 == "cpp" }.map(\.0).sorted()
            return headers + sources
        }
    }

    /// Renders the R sibling of `renderDriverScript`. Binds `seed` from the
    /// canonical base-R `chickadee_seed()` (shared with the grading runtime via
    /// `RPersonalizationRuntime`), `source()`s each support `.R` helper, binds
    /// every static variable via `rLiteral`, evaluates each R `= expression` in
    /// declared order, then emits — as the LAST stdout line — a JSON map
    /// `name → deparse(value)` (an R literal string per value). The Swift return
    /// path parses that last line identically for both languages, so only the
    /// driver bytes differ.
    static func renderRDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String] = []
    ) -> String {
        var lines: [String] = ["# Auto-generated personalization driver.  Do not edit.", ""]
        // Seed primitive — one source of truth with the grading runtime, so the
        // seed the driver binds equals the seed a grading script reads.
        lines.append(RPersonalizationRuntime.chickadeeSeedRSource)
        lines.append("")
        // JSON string encoder (char-by-char; avoids gsub replacement-escaping
        // ambiguity so backslash/quote-heavy deparse output encodes correctly).
        lines.append(rJSONStringEncoderSource)
        lines.append("")
        lines.append("seed <- chickadee_seed()")
        lines.append("")
        if !supportFiles.isEmpty {
            lines.append("# Auto-sourced support files (instructor .R helpers +")
            lines.append("# the solution.ipynb code cells extracted into solution.R).")
            lines.append("# A broken helper is ignored here; a missing name surfaces")
            lines.append("# as an error only if an expression actually references it.")
            for name in supportFiles {
                lines.append(
                    "tryCatch(source(\(JSONValue.string(name).rLiteral)), error = function(e) NULL)")
            }
            lines.append("")
        }
        if !staticVariables.isEmpty {
            lines.append("# Static globals + section variables (in scope for expressions).")
            for v in staticVariables {
                lines.append("`\(v.name)` <- \(v.value.rLiteral)")
            }
            lines.append("")
        }
        lines.append("# Per-student expressions, evaluated in declared order.")
        for e in expressions {
            lines.append("`\(e.name)` <- (\(e.expression))")
        }
        lines.append("")
        lines.append("# Emit one deparse(value) per declared expression as a JSON map")
        lines.append("# (the LAST stdout line — earlier instructor output is ignored).")
        lines.append(".ck_deparse1 <- function(x) paste(deparse(x), collapse = \" \")")
        lines.append(".ck_pairs <- character(0)")
        for e in expressions {
            let key = JSONValue.string(e.name).rLiteral
            lines.append(
                ".ck_pairs <- c(.ck_pairs, paste0(.ck_json_str(\(key)), \":\", "
                    + ".ck_json_str(.ck_deparse1(`\(e.name)`))))")
        }
        lines.append("cat(paste0(\"{\", paste(.ck_pairs, collapse = \",\"), \"}\"), \"\\n\", sep = \"\")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders the Lua sibling of `renderDriverScript`. Binds `seed` from the
    /// canonical `chickadee_seed()` (shared with the grading runtime via
    /// `LuaPersonalizationRuntime`, so the seed the driver binds equals the seed
    /// a grading script reads), `dofile`s each support `.lua` helper, binds the
    /// static variables, then evaluates the expressions in declared order.
    ///
    /// Two differences from the R driver, both forced by Lua:
    ///
    /// An expression is evaluated by compiling `return (<expr>)` with `load`
    /// rather than by assignment, because Lua has no `eval` and a chunk is the
    /// only way to turn source text into a value. Each is compiled against an
    /// environment carrying everything bound so far, which is what lets one
    /// expression reference an earlier one exactly as it can in R.
    ///
    /// The value is emitted through `chickadee_serialize`, which produces Lua
    /// SOURCE — the counterpart of R's `deparse`. The server writes that text
    /// verbatim into `_ck_inputs.lua`, so a display form would not do.
    static func renderLuaDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String] = []
    ) -> String {
        var lines: [String] = ["-- Auto-generated personalization driver.  Do not edit.", ""]
        lines.append(LuaPersonalizationRuntime.chickadeeSeedLuaSource)
        lines.append("")
        lines.append(LuaPersonalizationRuntime.chickadeeSerializeLuaSource)
        lines.append("")
        lines.append(LuaPersonalizationRuntime.chickadeeJSONStringLuaSource)
        lines.append("")
        // Names the expressions can see. Seeded with the globals so an
        // expression may call anything in the standard library, then extended
        // with `seed`, the support helpers, the static variables, and each
        // expression's own result as it is produced.
        lines.append("local scope = setmetatable({}, { __index = _G })")
        lines.append("scope.seed = chickadee_seed()")
        lines.append("")
        if !supportFiles.isEmpty {
            lines.append("-- Auto-loaded support files (instructor .lua helpers +")
            lines.append("-- the solution.ipynb code cells extracted into solution.lua).")
            lines.append("-- A broken helper is ignored here; a missing name surfaces")
            lines.append("-- as an error only if an expression actually references it.")
            for name in supportFiles {
                lines.append(
                    "do local chunk = loadfile(\(JSONValue.string(name).luaLiteral), \"t\", scope)")
                lines.append("   if chunk then pcall(chunk) end end")
            }
            lines.append("")
        }
        if !staticVariables.isEmpty {
            lines.append("-- Static globals + section variables (in scope for expressions).")
            for v in staticVariables {
                lines.append("scope[\(JSONValue.string(v.name).luaLiteral)] = \(v.value.luaLiteral)")
            }
            lines.append("")
        }
        lines.append("-- Per-student expressions, evaluated in declared order.")
        lines.append("local ck_names = {}")
        for e in expressions {
            let nameLiteral = JSONValue.string(e.name).luaLiteral
            // The expression text is embedded as a Lua string literal, so an
            // instructor's quotes and backslashes cannot break out of it.
            let bodyLiteral = JSONValue.string("return (\(e.expression))").luaLiteral
            lines.append("do")
            lines.append("    local chunk, err = load(\(bodyLiteral), \(nameLiteral), \"t\", scope)")
            lines.append(
                "    if not chunk then error(\"expression \" .. \(nameLiteral) .. \": \" .. tostring(err)) end")
            lines.append("    scope[\(nameLiteral)] = chunk()")
            lines.append("    ck_names[#ck_names + 1] = \(nameLiteral)")
            lines.append("end")
        }
        lines.append("")
        lines.append("-- Emit one chickadee_serialize(value) per declared expression as a JSON")
        lines.append("-- map (the LAST stdout line — earlier instructor output is ignored).")
        lines.append("local ck_pairs = {}")
        lines.append("for _, name in ipairs(ck_names) do")
        lines.append("    ck_pairs[#ck_pairs + 1] = chickadee_json_str(name) .. \":\"")
        lines.append("        .. chickadee_json_str(chickadee_serialize(scope[name]))")
        lines.append("end")
        lines.append("io.write(\"{\" .. table.concat(ck_pairs, \",\") .. \"}\\n\")")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders the Octave sibling of `renderDriverScript`. Opens with a `1;`
    /// script guard (the function definitions that follow would otherwise make
    /// the driver a FUNCTION FILE and nothing would execute), defines the
    /// shared personalization primitives from `OctavePersonalizationRuntime`
    /// (so the seed it binds and the seed a graded script reads are one
    /// implementation), loads each support `.m` helper's text behind the same
    /// guard, binds every static variable via `octaveLiteral`, evaluates each
    /// `= expression` in declared order, then emits — as the LAST stdout line —
    /// a JSON map `name → chickadee_serialize(value)` (an Octave literal
    /// string per value). The Swift return path parses that last line
    /// identically for every language, so only the driver bytes differ.
    static func renderOctaveDriverScript(
        staticVariables: [FamilyVariable],
        expressions: [PersonalizationExpression],
        supportFiles: [String] = []
    ) -> String {
        var lines: [String] = [
            "% Auto-generated personalization driver.  Do not edit.",
            "1;",
            "",
        ]
        lines.append(OctavePersonalizationRuntime.chickadeeSeedOctaveSource)
        lines.append("")
        lines.append(OctavePersonalizationRuntime.chickadeeEscapeStringOctaveSource)
        lines.append("")
        lines.append(OctavePersonalizationRuntime.chickadeeSerializeOctaveSource)
        lines.append("")
        lines.append("seed = chickadee_seed();")
        lines.append("")
        if !supportFiles.isEmpty {
            lines.append("% Auto-loaded support files (instructor .m helpers + the")
            lines.append("% solution.ipynb code cells extracted into solution.m). Each is")
            lines.append("% evaluated behind a `1;` guard so a one-function-per-file helper")
            lines.append("% registers under its own name instead of executing as a bare body.")
            lines.append("% A broken helper is ignored here; a missing name surfaces as an")
            lines.append("% error only if an expression actually references it.")
            for name in supportFiles {
                lines.append("try")
                lines.append(
                    "    eval([\"1;\" sprintf(\"\\n\") fileread(\(JSONValue.string(name).octaveLiteral))]);"
                )
                lines.append("catch")
                lines.append("end")
            }
            lines.append("")
        }
        if !staticVariables.isEmpty {
            lines.append("% Static globals + section variables (in scope for expressions).")
            for v in staticVariables {
                lines.append("\(octaveIdentifier(v.name)) = \(v.value.octaveLiteral);")
            }
            lines.append("")
        }
        lines.append("% Per-student expressions, evaluated in declared order. Each binds its")
        lines.append("% name in this workspace, so later expressions can reference earlier ones.")
        lines.append("ck_names = {};")
        for e in expressions {
            let nameLiteral = JSONValue.string(e.name).octaveLiteral
            // The expression text is embedded as an Octave string literal, so
            // an instructor's quotes and backslashes cannot break out of it.
            let bodyLiteral = JSONValue.string("(\(e.expression))").octaveLiteral
            lines.append("\(octaveIdentifier(e.name)) = eval(\(bodyLiteral));")
            lines.append("ck_names{end + 1} = \(nameLiteral);")
        }
        lines.append("")
        lines.append("% Emit one chickadee_serialize(value) per declared expression as a JSON")
        lines.append("% map (the LAST stdout line — earlier instructor output is ignored).")
        lines.append("ck_pairs = {};")
        lines.append("for ck_i = 1:numel(ck_names)")
        lines.append("    ck_pairs{end + 1} = [chickadee_escape_string(ck_names{ck_i}) \":\" ...")
        lines.append("        chickadee_escape_string(chickadee_serialize(eval(ck_names{ck_i})))];")
        lines.append("end")
        lines.append("printf(\"{%s}\\n\", strjoin(ck_pairs, \",\"));")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Base-R JSON string encoder used by the R driver's output stage. Encodes
    /// char-by-char (`utf8ToInt`/`intToUtf8`) so it never trips over `gsub`'s
    /// replacement-string backslash rules — deparse output is quote-heavy and
    /// occasionally backslash-heavy, and this must round-trip through
    /// `JSONSerialization` on the Swift side.
    private static let rJSONStringEncoderSource = #"""
        .ck_json_str <- function(x) {
            if (length(x) != 1L) x <- paste(as.character(x), collapse = "")
            x <- as.character(x)
            codes <- utf8ToInt(x)
            if (length(codes) == 0L) return("\"\"")
            out <- vapply(codes, function(cp) {
                if (cp == 34L) "\\\""
                else if (cp == 92L) "\\\\"
                else if (cp == 10L) "\\n"
                else if (cp == 13L) "\\r"
                else if (cp == 9L)  "\\t"
                else if (cp < 32L)  sprintf("\\u%04x", cp)
                else intToUtf8(cp)
            }, character(1L))
            paste0("\"", paste(out, collapse = ""), "\"")
        }
        """#

    /// Same identifier predicate the editor JS uses.  Used to filter
    /// support-file names down to legal Python module names.
    private static func isValidPyIdent(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Emits a Python-safe single-quoted string literal for an
    /// identifier-shape name.  Identifiers can't contain special chars,
    /// so quoting `'name'` directly is safe; no escaping needed.
    private static func stringLiteral(_ s: String) -> String {
        "'\(s)'"
    }

    /// Spawns a subprocess with the given env (merged with the parent's
    /// env), captures stdout/stderr, kills + reports timeout if it
    /// outruns `timeoutSeconds`.
    private static func spawnAndCapture(
        executableURL: URL,
        arguments: [String],
        cwd: URL,
        env: [String: String],
        timeoutSeconds: Int
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.currentDirectoryURL = cwd
        // SECURITY: do NOT inherit the parent process environment.  This
        // subprocess runs instructor-authored expressions, and the server
        // process holds secrets (RUNNER_SHARED_SECRET, database credentials,
        // the OIDC client secret, BrightSpace keys, …) that must never be
        // readable from an expression via `os.environ`.  Pass only an explicit
        // allowlist of variables the interpreter needs to start (PATH to locate
        // `python3`, plus HOME / locale / PYTHONHOME for the runtime), then
        // overlay the caller-supplied vars (the assignment seed and an optional
        // PYTHONPATH into the support-files dir).
        let parentEnv = ProcessInfo.processInfo.environment
        var mergedEnv: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "PYTHONHOME"] {
            if let value = parentEnv[key] { mergedEnv[key] = value }
        }
        for (k, v) in env { mergedEnv[k] = v }
        proc.environment = mergedEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw PersonalizationEvaluatorError.spawnFailed(String(describing: error))
        }

        let timeoutTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            if proc.isRunning {
                proc.terminate()
                // SIGTERM can be caught or ignored by the expression's
                // interpreter; escalate so the waitUntilExit below is
                // actually bounded.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                return true
            }
            return false
        }

        // Drain both pipes BEFORE waiting for exit, concurrently and with a
        // deadline. Reading after waitUntilExit() deadlocked once the child
        // filled a 64 KiB pipe buffer (a long expression output became a
        // spurious .timedOut plus a blocked thread), and draining the pipes
        // sequentially just moves the same deadlock to the other pipe. EOF
        // normally arrives when the child exits or the timeout terminates
        // it; the deadline covers an expression that leaks a grandchild
        // holding the pipe open (docs/ci-flakiness.md, remaining attack
        // order).
        let drainDeadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds) + 2)
        async let stdoutBytes = Self.readToEnd(
            fileDescriptor: outPipe.fileHandleForReading.fileDescriptor, deadline: drainDeadline)
        async let stderrBytes = Self.readToEnd(
            fileDescriptor: errPipe.fileHandleForReading.fileDescriptor, deadline: drainDeadline)
        let stdoutData = await stdoutBytes
        let stderrData = await stderrBytes
        proc.waitUntilExit()
        // Wake the timeout task now instead of letting its full sleep gate
        // the return path: a cancelled sleep falls through to the same
        // isRunning check, which is false for a normally-exited child.
        timeoutTask.cancel()
        let didTimeOut = await timeoutTask.value

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if didTimeOut {
            throw PersonalizationEvaluatorError.timedOut
        }
        return (stdout, stderr, proc.terminationStatus)
    }

    /// Reads a pipe descriptor toward EOF on a dedicated thread, keeping the
    /// blocking reads (and the pipe-buffer backpressure) off the cooperative
    /// pool. Bounded by `deadline`: if a leaked grandchild still holds the
    /// write end after the child is gone, we return what we have instead of
    /// stalling a server thread indefinitely.
    private static func readToEnd(fileDescriptor: Int32, deadline: Date) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var collected = Data()
                var chunk = [UInt8](repeating: 0, count: 65_536)
                while true {
                    var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let readyCount = poll(&pollDescriptor, 1, 100)
                    if readyCount == -1 {
                        if errno == EINTR { continue }
                        break
                    }
                    if readyCount > 0 {
                        let bytesRead = read(fileDescriptor, &chunk, chunk.count)
                        if bytesRead > 0 {
                            collected.append(contentsOf: chunk[0..<bytesRead])
                            continue
                        }
                        if bytesRead == -1 && errno == EINTR { continue }
                        break  // 0 = EOF (all write ends closed); -1 = unrecoverable.
                    }
                    if Date() >= deadline { break }
                }
                continuation.resume(returning: collected)
            }
        }
    }
}
