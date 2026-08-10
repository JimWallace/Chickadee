// Worker/TestRuntimeSources.swift
//
// Inline copies of every language's test helper library, injected into each test
// working directory by the runner before execution.
//
// The canonical sources live in `Tools/runner-support/` and are kept in sync by
// hand; `RuntimeSourceDriftTests` asserts the two copies agree. Neither this
// comment nor that test names the files — both walk
// `runtimeHelperFiles(for:)` below, which is exhaustive on
// `AssignmentLanguage`. A prose list here was how `test_runtime.rkt` came to sit
// in `Tools/runner-support/` with no embed and no test for an entire release.

import Core
import Foundation

let testRuntimePy = """
    import inspect
    import importlib.util
    import json
    import sys
    import traceback
    from pathlib import Path
    from typing import Dict, List, Optional, Any


    def _caller_file(depth: int = 3) -> Path:
        frame = inspect.stack()[depth]
        return Path(frame.filename)


    def _first_comment_label() -> str:
        path = _caller_file()
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                s = line.strip()
                if not s:
                    continue
                if s.startswith("#!") or s.startswith("# -*-"):
                    continue
                if s.startswith("#"):
                    label = s.lstrip("#").strip()
                    return label if label else path.stem
                break
        except Exception:
            pass
        return path.stem


    def _emit(payload: Dict[str, object]) -> None:
        print(json.dumps(payload, ensure_ascii=False))


    def _first_nonempty_line(text: str) -> str:
        for raw in text.splitlines():
            line = raw.strip()
            if line:
                return line
        return ""


    def passed(message: Optional[str] = None):
        label = _first_comment_label()
        _emit({
            "shortResult": message or f"{label}: passed",
            "status": "pass",
            "test": label,
        })
        raise SystemExit(0)


    def failed(message: str = "failed"):
        label = _first_comment_label()
        text = message if isinstance(message, str) else str(message)
        summary = _first_nonempty_line(text) or "failed"
        if text.strip() and text.strip() != "failed":
            print(text)
        _emit({
            "shortResult": f"{label}: {summary}",
            "status": "fail",
            "test": label,
            "error": text,
        })
        raise SystemExit(1)


    def errored(message: str = "error", err: Optional[Exception] = None):
        label = _first_comment_label()
        text = message if isinstance(message, str) else str(message)
        summary = _first_nonempty_line(text) or "error"
        if text.strip() and text.strip() != "error":
            print(text)
        payload = {
            "shortResult": f"{label}: {summary}",
            "status": "error",
            "test": label,
            "error": summary,
        }
        if err is not None:
            payload["exception"] = repr(err)
            payload["traceback"] = traceback.format_exc()
        _emit(payload)
        raise SystemExit(2)


    def _candidate_student_files() -> List[Path]:
        cwd = Path(".")
        files: List[Path] = []
        for p in cwd.glob("*.py"):
            name = p.name
            if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py", "_ck_inputs.py"}:
                continue
            lower = name.lower()
            if lower.startswith("publictest") or lower.startswith("secrettest") or lower.startswith("releasetest"):
                continue
            files.append(p)
        return sorted(files, key=_student_file_sort_key)


    def _student_file_sort_key(path: Path):
        lower = path.name.lower()
        if lower == "assignment.py":
            return (90, lower)
        if lower in {"solution.py", "submission.py"}:
            return (0, lower)
        return (10, lower)


    def _preferred_student_module() -> Optional[Path]:
        hint = Path(".chickadee_student_module")
        if not hint.exists():
            return None
        try:
            raw = hint.read_text(encoding="utf-8").strip()
        except Exception:
            return None
        if not raw:
            return None
        preferred = Path(raw).name
        if not preferred.endswith(".py"):
            return None
        path = Path(preferred)
        return path if path.exists() else None


    def _module_name_for_path(path: Path) -> str:
        stem = path.stem
        safe = "".join(ch if (ch.isalnum() or ch == "_") else "_" for ch in stem)
        if not safe:
            safe = "student"
        if safe[0].isdigit():
            safe = f"m_{safe}"
        return f"student_{safe}"


    def _ordered_student_files() -> List[Path]:
        preferred = _preferred_student_module()
        # When a specific submission module is hinted, only evaluate that file.
        # This avoids accidentally resolving functions from setup-side helpers
        # like solution.py/assignment.py.
        if preferred is not None:
            return [preferred]
        return _candidate_student_files()


    _loaded_student_modules: Optional[Dict[str, Any]] = None
    _loaded_student_order: List[str] = []
    _student_module_errors: Dict[str, str] = {}


    def load_student_modules(force_reload: bool = False) -> Dict[str, Any]:
        global _loaded_student_modules, _loaded_student_order, _student_module_errors
        if _loaded_student_modules is not None and not force_reload:
            return _loaded_student_modules

        modules: Dict[str, Any] = {}
        order: List[str] = []
        errors: Dict[str, str] = {}

        for path in _ordered_student_files():
            key = path.name
            try:
                module_name = _module_name_for_path(path)
                spec = importlib.util.spec_from_file_location(module_name, path)
                if spec is None or spec.loader is None:
                    errors[key] = "Could not create import spec."
                    continue
                module = importlib.util.module_from_spec(spec)
                sys.modules[module_name] = module
                spec.loader.exec_module(module)
                modules[key] = module
                order.append(key)
            except Exception:
                errors[key] = traceback.format_exc()

        _loaded_student_modules = modules
        _loaded_student_order = order
        _student_module_errors = errors
        return modules


    def student_module_errors() -> Dict[str, str]:
        return _student_module_errors


    def student_module_names_in_load_order() -> List[str]:
        return list(_loaded_student_order)


    def load_student_module():
        modules = load_student_modules()
        if not _loaded_student_order:
            return None
        return modules.get(_loaded_student_order[0])


    _student_main_state = None


    def student_main_state():
        # The student notebook AS EXECUTED — top-level side effects included.
        # The extractor quarantines side-effecting top-level statements into
        # `if __name__ == "__main__":` so imports stay safe (issue #371);
        # runtime-state checks call this to run the student file once with
        # run_name="__main__" (per-cell try/except still isolates broken
        # cells) and inspect the resulting namespace. Falls back to the
        # import-mode module when no student file exists or the run fails.
        global _student_main_state
        if _student_main_state is not None:
            return _student_main_state
        import runpy
        import types

        files = _ordered_student_files()
        if not files:
            return load_student_module()
        try:
            namespace = runpy.run_path(str(files[0]), run_name="__main__")
            _student_main_state = types.SimpleNamespace(**namespace)
        except Exception:
            print(traceback.format_exc(), file=sys.stderr)
            return load_student_module()
        return _student_main_state


    def student_source_raw() -> str:
        # The full introspectable student source, exactly as the extractor wrote
        # it (every cell, including any that do not parse). Written to a sidecar
        # named by the `.chickadee_student_source` hint (both runners share one
        # extractor); falls back to inspect.getsource on the loaded module. Use
        # this for raw text inspection; use student_source() / student_ast() for
        # parse-based checks.
        hint = Path(".chickadee_student_source")
        try:
            if hint.exists():
                name = Path(hint.read_text(encoding="utf-8").strip()).name
                sidecar = Path(name)
                if name and sidecar.exists():
                    return sidecar.read_text(encoding="utf-8")
        except Exception:
            pass
        try:
            import inspect
            module = load_student_module()
            if module is not None:
                return inspect.getsource(module)
        except Exception:
            pass
        return ""


    def student_cell_sources() -> List[Any]:
        # Split the raw student source into (label, source) chunks on the
        # `# --- cell N ---` markers the notebook extractor writes between cells,
        # so each notebook cell can be parsed on its own. A raw .py submission has
        # no markers and yields a single ("module", source) chunk.
        source = student_source_raw()
        chunks: List[Any] = []
        label = "module"
        lines: List[str] = []
        for raw in source.split("\\n"):
            stripped = raw.strip()
            if stripped.startswith("# --- ") and stripped.endswith(" ---"):
                if lines:
                    chunks.append((label, "\\n".join(lines)))
                label = stripped[6:-4].strip() or "module"
                lines = []
            else:
                lines.append(raw)
        if lines:
            chunks.append((label, "\\n".join(lines)))
        if not chunks:
            chunks.append(("module", source))
        return chunks


    def student_ast(skipped: Optional[List[Any]] = None) -> Any:
        # Best-effort AST of the student's source: parse each notebook cell on its
        # own and merge the parseable cells' top-level statements into one module.
        # A single non-Python cell (Markdown pasted into a code cell, a half-written
        # cell) is then skipped instead of blinding a style/structure check on every
        # other cell -- mirroring the per-cell resilience of the executable module.
        # `skipped`, if a list, receives an (label, message) tuple per dropped cell.
        import ast
        module = ast.parse("")
        for label, chunk in student_cell_sources():
            if not chunk.strip():
                continue
            try:
                node = ast.parse(chunk)
            except SyntaxError as ex:
                if skipped is not None:
                    skipped.append((label, f"{type(ex).__name__}: {ex}"))
                continue
            module.body.extend(node.body)
        return module


    def student_source() -> str:
        # Best-effort *parseable* introspectable source: like student_source_raw(),
        # but any single cell that does not parse on its own is dropped, so callers
        # that do `ast.parse(student_source())` are not blinded by one non-Python
        # cell (e.g. a Markdown cell saved as a code cell). When nothing needs
        # dropping the raw source is returned verbatim. Use student_source_raw()
        # for the unfiltered text.
        import ast
        parts: List[str] = []
        dropped = False
        for label, chunk in student_cell_sources():
            if chunk.strip():
                try:
                    ast.parse(chunk)
                except SyntaxError:
                    dropped = True
                    continue
            parts.append(f"# --- {label} ---\\n{chunk}")
        if not dropped or not parts:
            return student_source_raw()
        return "\\n\\n".join(parts) + "\\n"


    def require_function(name: str, num_args: Optional[int] = None):
        modules = load_student_modules()
        for key in _loaded_student_order:
            module = modules.get(key)
            if module is None:
                continue
            fn = getattr(module, name, None)
            if fn is not None and callable(fn):
                if num_args is not None:
                    _require_num_args(fn, name, num_args)
                return fn

        if not modules:
            errors = student_module_errors()
            if errors:
                first_name = next(iter(errors.keys()))
                print(errors[first_name], end="")
                errored("SyntaxError in submission")
            errored("Could not load a student Python module from submission.")

        errored(f"Required function '{name}' was not found or is not callable in loaded student modules.")


    def _require_num_args(fn: Any, name: str, num_args: int) -> None:
        try:
            sig = inspect.signature(fn)
        except (TypeError, ValueError):
            return
        positional_kinds = {
            inspect.Parameter.POSITIONAL_ONLY,
            inspect.Parameter.POSITIONAL_OR_KEYWORD,
        }
        positional = [p for p in sig.parameters.values() if p.kind in positional_kinds]
        required = sum(1 for p in positional if p.default is inspect.Parameter.empty)
        accepts_varargs = any(
            p.kind == inspect.Parameter.VAR_POSITIONAL for p in sig.parameters.values()
        )
        total = len(positional)
        if accepts_varargs:
            if num_args < required:
                errored(
                    f"'{name}' requires at least {required} positional argument(s), "
                    f"but the test expects it to take {num_args}."
                )
            return
        if not (required <= num_args <= total):
            if required == total:
                errored(
                    f"'{name}' should take {num_args} argument(s), but it takes {total}."
                )
            else:
                errored(
                    f"'{name}' should take {num_args} argument(s), "
                    f"but it takes {required}-{total}."
                )
    """

let sitecustomizePy = """
    import builtins
    import test_runtime as _tr

    builtins.passed = _tr.passed
    builtins.failed = _tr.failed
    builtins.errored = _tr.errored
    builtins.require_function = _tr.require_function

    _student_modules = _tr.load_student_modules()
    builtins.student_modules = _student_modules
    _student_module = _tr.load_student_module()
    builtins.student_module = _student_module
    for _module_name in _tr.student_module_names_in_load_order():
        _module = _student_modules.get(_module_name)
        if _module is None:
            continue
        for _name, _value in vars(_module).items():
            if _name.startswith("_"):
                continue
            if callable(_value) and not hasattr(builtins, _name):
                setattr(builtins, _name, _value)
    """

// MARK: - R test runtime

// Injected into every test working directory alongside the Python helpers.
// Hand-formatted JSON output avoids any dependency on jsonlite or other packages
// that may not be present on a bare R install.
//
// Mirrors the canonical source in Tools/runner-support/test_runtime.R.
// Keep the two in sync when making changes here.
private let testRuntimeRHelpers = #"""
    # test_runtime.R — Chickadee R test helper library.
    # Source at the top of each R test script: source("test_runtime.R")
    #
    # API:
    #   passed(message = NULL)     — exit 0  (pass)
    #   failed(message = "failed") — exit 1  (fail)
    #   errored(message = "error") — exit 2  (error)
    #
    # No external package dependencies; JSON is hand-formatted so this works
    # on bare R installs without jsonlite.

    .chickadee_json_str <- function(x) {
        x <- as.character(x)
        x <- gsub("\\", "\\\\", x, fixed = TRUE)
        x <- gsub('"',    '\\"',    x, fixed = TRUE)
        x <- gsub("\n",   "\\n",    x, fixed = TRUE)
        x <- gsub("\r",   "\\r",    x, fixed = TRUE)
        x <- gsub("\t",   "\\t",    x, fixed = TRUE)
        paste0('"', x, '"')
    }

    .chickadee_label <- function() {
        args  <- commandArgs(trailingOnly = FALSE)
        fargs <- args[startsWith(args, "--file=")]
        if (length(fargs) > 0L) {
            path <- sub("^--file=", "", fargs[[1L]])
            return(tools::file_path_sans_ext(basename(path)))
        }
        "test"
    }

    .chickadee_emit <- function(status, short_result, error = NULL) {
        label <- .chickadee_label()
        parts <- c(
            paste0('"status":',      .chickadee_json_str(status)),
            paste0('"shortResult":', .chickadee_json_str(short_result)),
            paste0('"test":',        .chickadee_json_str(label))
        )
        if (!is.null(error)) {
            parts <- c(parts, paste0('"error":', .chickadee_json_str(as.character(error))))
        }
        cat(paste0("{", paste(parts, collapse = ","), "}\n"))
    }

    passed <- function(message = NULL) {
        label <- .chickadee_label()
        msg   <- if (!is.null(message)) as.character(message) else paste0(label, ": passed")
        .chickadee_emit("pass", msg)
        quit(status = 0L, save = "no")
    }

    failed <- function(message = "failed") {
        label <- .chickadee_label()
        msg   <- as.character(message)
        .chickadee_emit("fail", paste0(label, ": ", msg), error = msg)
        quit(status = 1L, save = "no")
    }

    errored <- function(message = "error") {
        label <- .chickadee_label()
        msg   <- as.character(message)
        .chickadee_emit("error", paste0(label, ": ", msg), error = msg)
        quit(status = 2L, save = "no")
    }

    # --- Value formatting + comparison ------------------------------------------
    # Used by generated pattern-family tests (and available to hand-authored
    # ones) so failure messages read the same whatever produced the test.

    # One-line, student-readable rendering of a value - the R analogue of
    # Python's repr(). Collapsed to a single line and truncated so a failure
    # message stays scannable.
    chickadee_format <- function(x, max_chars = 300L) {
        s <- tryCatch(paste(deparse(x), collapse = " "), error = function(e) "<unprintable>")
        s <- gsub("[[:space:]]+", " ", s)
        if (nchar(s) > max_chars) paste0(substr(s, 1L, max_chars), " ...") else s
    }

    # Exact equality, with JSON-friendly numeric handling: an expected value
    # decoded from the family spec is a double (1), while a student may well
    # return an integer (1L). Comparing numerics by value keeps that difference
    # from failing an otherwise-correct answer. Everything else falls back to
    # all.equal's structural comparison (names, nesting, attributes).
    chickadee_equal <- function(actual, expected) {
        if (is.numeric(actual) && is.numeric(expected)) {
            if (length(actual) != length(expected)) return(FALSE)
            return(isTRUE(all(actual == expected)))
        }
        if (is.logical(actual) && is.logical(expected)) {
            if (length(actual) != length(expected)) return(FALSE)
            return(isTRUE(all(actual == expected)))
        }
        isTRUE(all.equal(actual, expected))
    }

    # Order-insensitive comparison for the unordered_equality kind: same
    # elements, any order. Compared as characters so mixed numeric/integer
    # element types do not matter.
    chickadee_unordered_equal <- function(actual, expected) {
        a <- tryCatch(unlist(actual, use.names = FALSE), error = function(e) NULL)
        b <- tryCatch(unlist(expected, use.names = FALSE), error = function(e) NULL)
        if (is.null(a) || is.null(b)) return(FALSE)
        if (length(a) != length(b)) return(FALSE)
        isTRUE(all(sort(as.character(a)) == sort(as.character(b))))
    }
    """#

// Locating the student's submission — the R mirror of `test_runtime.py`'s
// `_preferred_student_module()` / `_candidate_student_files()`. Python reserves
// its own workspace filenames inside the runtime; R had no equivalent, so every
// assignment's helper hand-rolled the search and each one had to remember to
// skip `_ck_inputs.R` on its own. Centralizing it here makes the reservation
// real: the reserved inputs filename is interpolated straight from
// `AssignmentLanguage`, so the skip list cannot drift from the file the worker
// actually writes.
private let testRuntimeRStudentFile = #"""
    # --- Locating the student's submission --------------------------------------
    # Filenames Chickadee itself writes into the grading workspace. None of them is
    # ever the student's submission, so they are never candidates.
    .chickadee_reserved_files <- c("test_runtime.R", "\#(AssignmentLanguage.r.inputsFileName)")

    .chickadee_is_test_file <- function(names) {
        grepl("^(publictest|releasetest|secrettest|studenttest)", names)
    }

    # The test script currently executing. It is itself a .R file sitting in the
    # working directory, so it must never be mistaken for the submission - the
    # tier-prefix rule above only covers the conventional names.
    .chickadee_running_script <- function() {
        args  <- commandArgs(trailingOnly = FALSE)
        fargs <- args[startsWith(args, "--file=")]
        if (length(fargs) > 0L) return(basename(sub("^--file=", "", fargs[[1L]])))
        ""
    }

    # The student's submitted R file: solution.R during validation, the extracted
    # notebook during grading. Prefers the runner's `.chickadee_student_module`
    # hint when it names an R file that is actually present, then falls back to
    # scanning the working directory. `extra_skip` lets an assignment exclude its
    # own bundled helpers, e.g. chickadee_student_file(c("a2_helpers.R")).
    # Returns NA_character_ when nothing looks like a submission.
    chickadee_student_file <- function(extra_skip = character(0)) {
        hint_path <- ".chickadee_student_module"
        if (file.exists(hint_path)) {
            hinted <- tryCatch(trimws(readLines(hint_path, warn = FALSE)),
                               error = function(e) character(0))
            hinted <- hinted[nzchar(hinted)]
            if (length(hinted) > 0L) {
                preferred <- basename(hinted[[1L]])
                if (grepl("\\.[Rr]$", preferred) && file.exists(preferred)) return(preferred)
            }
        }
        rfiles <- list.files(pattern = "\\.[Rr]$")
        skip   <- c(.chickadee_reserved_files, .chickadee_running_script(), extra_skip)
        cand   <- rfiles[!(rfiles %in% skip) & !.chickadee_is_test_file(rfiles)]
        if (length(cand) == 0L) return(NA_character_)
        if ("solution.R" %in% cand) return("solution.R")
        cand[[1L]]
    }

    # Evaluate the submission expression-by-expression in a fresh environment, so a
    # runtime error in one top-level line still leaves the function definitions
    # that loaded before it available to the tests.
    chickadee_load_student <- function(extra_skip = character(0)) {
        f <- chickadee_student_file(extra_skip)
        if (is.na(f)) errored("No R submission file was found to grade.")

        env <- new.env(parent = globalenv())
        grDevices::pdf(NULL)                 # swallow any plots the notebook draws
        on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)

        exprs <- tryCatch(parse(file = f), error = function(e) NULL)
        if (is.null(exprs)) {
            errored(paste0("Your submission (", f, ") could not be parsed as R - check for a syntax error."))
        }
        for (ex in exprs) tryCatch(eval(ex, envir = env), error = function(e) invisible(NULL))
        env
    }

    # Split the submission back into the notebook cells it was flattened from.
    # `extractNotebooksToCode` writes an inert marker comment ahead of each code
    # cell, which is what gives a source-level check cell granularity that plain
    # concatenation loses. A submission that never came from a notebook (a
    # hand-written .R upload) has no markers, so the whole file is returned as one
    # cell — file granularity, which is the honest answer for a file with no cells.
    chickadee_student_cells <- function(extra_skip = character(0)) {
        f <- chickadee_student_file(extra_skip)
        if (is.na(f)) errored("No R submission file was found to grade.")
        lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
        starts <- which(grepl("^# ---- chickadee:cell [0-9]+ ----$", lines))
        if (length(starts) == 0L) return(paste(lines, collapse = "\n"))
        ends <- c(starts[-1L] - 1L, length(lines))
        out <- character(length(starts))
        for (i in seq_along(starts)) {
            first <- starts[[i]] + 1L
            out[[i]] <- if (first > ends[[i]]) "" else paste(lines[first:ends[[i]]], collapse = "\n")
        }
        out
    }

    # Fetch a function the student was asked to write; a clear error when it is
    # missing or was overwritten with something that is not a function.
    chickadee_require_fn <- function(env, name) {
        fn <- tryCatch(get(name, envir = env, inherits = FALSE), error = function(e) NULL)
        if (is.null(fn) || !is.function(fn)) {
            errored(sprintf("Your submission must define a function called `%s()`.", name))
        }
        fn
    }
    """#

// The full R runtime = the helper library above + submission location + the
// per-student personalization primitives (`chickadee_seed()` /
// `chickadee_inputs()`), whose source lives in Core (`RPersonalizationRuntime`)
// so a grading script computes the seed identically to the server-side
// expression driver. Composing from the one Core source — rather than
// re-pasting the R here — is what guarantees the two never drift.
// `Tools/runner-support/test_runtime.R` carries the same pieces for
// standalone/manual runs and is kept in sync by hand.
let testRuntimeR =
    testRuntimeRHelpers + "\n\n"
    + RPersonalizationRuntime.chickadeeSeedRSource + "\n\n"
    + RPersonalizationRuntime.chickadeeInputsRSource + "\n\n"
    + testRuntimeRStudentFile + "\n"

// MARK: - Lua

// The Lua test helper library, injected into every test working directory
// alongside the Python and R ones. Byte-for-byte the canonical
// `Tools/runner-support/test_runtime.lua`; `RuntimeSourceDriftTests` fails if
// the two diverge.
//
// Unlike the R runtime, this is one literal rather than a composition of Core
// sources. The seed reduction it carries is deliberately the SAME Horner fold
// R uses (`RPersonalizationRuntime.chickadeeSeedRSource`), so a student's seed
// is one number in every language — but there is no Lua expression driver on
// the server to share a Core constant with yet, and inventing one to hold a
// single function would be a seam with nothing on the other side of it. When
// Lua personalization arrives (see docs/adding-a-xeus-kernel.md, "Where the
// second half begins"), this is the piece that moves to Core.
let testRuntimeLua =
    #"""
    -- test_runtime.lua — Chickadee Lua test helper library.
    -- Require at the top of each Lua test script:
    --     local t = require("test_runtime")
    --
    -- API (a module table, the Lua idiom — R sources a file and Python imports
    -- names, but a Lua library that assigned globals would be a surprise):
    --   t.passed(message)            — exit 0  (pass)
    --   t.failed(message)            — exit 1  (fail)
    --   t.errored(message)           — exit 2  (error)
    --   t.label()                    — the test's name, from arg[0]
    --   t.seed()                     — deterministic per-student integer seed
    --   t.inputs()                   — per-student inputs from _ck_inputs.lua
    --   t.student_file()             — the submitted .lua file to grade
    --   t.load_student()             — that file, loaded into a fresh environment
    --   t.require_fn(env, name)      — fetch a function the student had to write
    --   t.format(value)              — one-line rendering, for failure messages
    --   t.equal(a, b)                — value equality across Lua's number types
    --
    -- No external dependencies: JSON is hand-formatted, so this works on a bare
    -- `lua` install and inside the xeus-lua kernel alike.
    --
    -- WHAT MAKES THIS FILE WORK IN BOTH RUNNERS, which is the whole difficulty.
    -- The native runner spawns `lua publictest_foo.lua`, so the contract is a
    -- PROCESS contract: os.exit sets the status, arg[0] names the script,
    -- os.getenv reads the environment. A xeus-lua kernel has none of those — there
    -- is no process to exit and no argv. Rather than fork this file, the browser
    -- wrapper (Public/lua-grading-shared.js) re-creates that contract inside one
    -- Lua session by masking `os.exit`, `os.getenv` and `arg` before the script
    -- runs. This file therefore stays byte-identical across both runners, exactly
    -- as test_runtime.R does. Do not replace os.exit with a `return`-based
    -- protocol: under `lua` that would exit 0 for a failing test.

    local M = {}

    local function json_str(value)
        local s = tostring(value)
        s = s:gsub("\\", "\\\\")
        s = s:gsub('"', '\\"')
        s = s:gsub("\n", "\\n")
        s = s:gsub("\r", "\\r")
        s = s:gsub("\t", "\\t")
        return '"' .. s .. '"'
    end

    -- The test's name, as the grader labels it: the script filename without its
    -- directory or extension. `arg` is what `lua script.lua` populates and what
    -- the browser wrapper masks, so both runners answer the same thing.
    function M.label()
        local path = (type(arg) == "table" and arg[0]) or ""
        local base = path:match("([^/\\]+)$") or path
        local stem = base:match("^(.*)%.[^.]*$") or base
        if stem == "" then return "test" end
        return stem
    end

    -- The script currently executing, with its extension — never mistakable for
    -- the student's submission when scanning the working directory.
    local function running_script()
        local path = (type(arg) == "table" and arg[0]) or ""
        return path:match("([^/\\]+)$") or ""
    end

    local function emit(status, short_result, err)
        local parts = {
            '"status":' .. json_str(status),
            '"shortResult":' .. json_str(short_result),
            '"test":' .. json_str(M.label()),
        }
        if err ~= nil then
            parts[#parts + 1] = '"error":' .. json_str(err)
        end
        io.write("{" .. table.concat(parts, ",") .. "}\n")
    end

    function M.passed(message)
        local msg = message ~= nil and tostring(message) or (M.label() .. ": passed")
        emit("pass", msg)
        os.exit(0)
    end

    function M.failed(message)
        local msg = tostring(message == nil and "failed" or message)
        emit("fail", M.label() .. ": " .. msg, msg)
        os.exit(1)
    end

    function M.errored(message)
        local msg = tostring(message == nil and "error" or message)
        emit("error", M.label() .. ": " .. msg, msg)
        os.exit(2)
    end

    -- --- Value formatting + comparison -----------------------------------------
    -- Used by hand-authored tests so failure messages read the same whatever
    -- produced them. The Lua analogue of chickadee_format / chickadee_equal in
    -- test_runtime.R.

    -- One-line, student-readable rendering. Tables are shown one level deep with
    -- their array part in order, which is what a test's expected value normally
    -- is; anything deeper is elided rather than recursed, so a cyclic table cannot
    -- hang the grader.
    function M.format(value, max_chars)
        max_chars = max_chars or 300
        local rendered
        if type(value) == "string" then
            rendered = string.format("%q", value)
        elseif type(value) ~= "table" then
            rendered = tostring(value)
        else
            local parts = {}
            for _, item in ipairs(value) do
                parts[#parts + 1] = type(item) == "table" and "{...}" or tostring(item)
            end
            rendered = "{" .. table.concat(parts, ", ") .. "}"
        end
        if #rendered > max_chars then
            return rendered:sub(1, max_chars) .. " ..."
        end
        return rendered
    end

    -- The stand-in for a JSON null inside a generated table literal.
    --
    -- Lua has no missing-value scalar, and a bare `nil` in a table constructor is
    -- not stored at all: `{60, nil, 20}` makes `ipairs` stop after one element and
    -- `table.concat` raise, so an authored case's positional alignment is silently
    -- lost. A sentinel TABLE is a real value and occupies its slot. This is Lua's
    -- answer to the problem R solves with `NA` (see `JSONValue.luaLiteral`, which
    -- emits `chickadee.NULL` and is what requires this to exist under that name).
    --
    -- Compared by identity, so nothing a student can construct is equal to it.
    M.NULL = \#(LuaPersonalizationRuntime.chickadeeNullSentinelLuaSource)

    -- Exact equality, with Lua 5.4's integer/float split handled the way a student
    -- would expect: 1 and 1.0 are the same answer. `==` already says so for
    -- numbers, so the only work is comparing array-like tables element by element.
    --
    -- `M.NULL` is equal only to itself. It must be checked BEFORE the table arm,
    -- or two distinct sentinels would compare equal as empty tables — which would
    -- be harmless today but wrong the moment a student returned `{}`.
    function M.equal(actual, expected)
        if actual == M.NULL or expected == M.NULL then
            return rawequal(actual, expected)
        end
        if type(actual) == "table" and type(expected) == "table" then
            if #actual ~= #expected then return false end
            for i = 1, #actual do
                if not M.equal(actual[i], expected[i]) then return false end
            end
            return true
        end
        return actual == expected
    end

    -- Order-insensitive comparison for the unordered_equality kind: the two arrays
    -- hold the same elements in any order. Defined in terms of `M.equal`, greedily
    -- pairing each actual element with an as-yet-unused expected one — so it can
    -- NEVER disagree with `equal`, because it IS `equal`, applied pairwise.
    --
    -- The previous version keyed each element through a string rendering and sorted
    -- the keys, which was a second, weaker notion of equality living beside the real
    -- one. It disagreed with `equal` in both directions: `{1}` vs `{1.0}` rendered
    -- "1" vs "1.0" and failed while `equal(1, 1.0)` passed; and `{ {"a, b"} }` vs
    -- `{ {"a", "b"} }` rendered alike (the comma-join) and passed while they are
    -- plainly different. Keying only reached the top level, so nested tables were
    -- worse still. Delegating to `equal` removes the whole second notion.
    --
    -- Greedy matching is exact here because `equal` is an equivalence relation
    -- (exact value equality is transitive): if an actual element equals several
    -- expected ones they are mutually equal, so consuming any is safe. O(n^2),
    -- which is nothing at the sizes a generated case compares.
    function M.unordered_equal(actual, expected)
        if type(actual) ~= "table" or type(expected) ~= "table" then
            return false
        end
        if #actual ~= #expected then return false end
        local used = {}
        for i = 1, #actual do
            local matched = false
            for j = 1, #expected do
                if not used[j] and M.equal(actual[i], expected[j]) then
                    used[j] = true
                    matched = true
                    break
                end
            end
            if not matched then return false end
        end
        return true
    end

    -- --- Per-student personalization primitives ---------------------------------
    -- Mirror of chickadee_seed() in test_runtime.R and the Python equivalent. Lua
    -- 5.4 has 64-bit integers but no bignum, so the 256-bit hex seed is folded with
    -- Horner's method modulo 2^31-1 — the SAME reduction R uses, so a student's
    -- seed is one number whatever language the assignment is in.

    function M.seed()
        local raw = os.getenv("CHICKADEE_ASSIGNMENT_SEED") or ""
        local hex = raw:lower():gsub("[^0-9a-f]", "")
        if hex == "" then return 0 end
        local modulus = 2147483647  -- 2^31 - 1; intermediates stay well inside 2^53
        local acc = 0
        for i = 1, #hex do
            acc = (acc * 16 + tonumber(hex:sub(i, i), 16)) % modulus
        end
        return math.tointeger(acc) or acc
    end

    -- The per-student grading inputs the worker materialized into _ck_inputs.lua
    -- (a chunk returning a table), or an empty table when none were delivered.
    -- The chunk is loaded with `chickadee` bound, because the values in it were
    -- rendered by `JSONValue.luaLiteral`, which spells a JSON null inside a table
    -- as the sentinel `chickadee.NULL` (Lua stores no `nil` in a constructor, so a
    -- hole would silently eat an authored case's positional alignment).
    --
    -- Binding it HERE rather than making the file `require` the runtime itself
    -- keeps `_ck_inputs.lua` a pure data chunk with no dependencies — which is what
    -- lets the conformance matrix write one into an empty directory and read it
    -- back. Without the binding a single null makes the chunk raise, `pcall`
    -- swallows it, this returns `{}`, and every per-student value silently reads as
    -- missing: a wrong mark rather than a crash.
    function M.inputs()
        local env = setmetatable({ chickadee = M }, { __index = _G })
        local chunk = loadfile("_ck_inputs.lua", "t", env)
        if not chunk then return {} end
        local ok, value = pcall(chunk)
        if ok and type(value) == "table" then return value end
        return {}
    end

    -- --- Locating the student's submission --------------------------------------
    -- Filenames Chickadee itself writes into the grading workspace are never the
    -- student's submission.
    local RESERVED = { ["test_runtime.lua"] = true, ["_ck_inputs.lua"] = true }

    local function is_test_file(name)
        return name:match("^publictest") ~= nil
            or name:match("^releasetest") ~= nil
            or name:match("^secrettest") ~= nil
            or name:match("^studenttest") ~= nil
    end

    -- The student's submitted Lua file: solution.lua during validation, the
    -- extracted notebook during grading.
    --
    -- Unlike R and Python, this reads ONLY the runner's `.chickadee_student_module`
    -- hint, with `solution.lua` as the fallback. Lua's standard library cannot list
    -- a directory — there is no `list.files` and no `os.listdir`, and `io.popen`
    -- is a subprocess the wasm kernel does not have — so the scan those two fall
    -- back to has no Lua equivalent. The hint is written by the runner on every
    -- job, so this is the normal path rather than a degraded one.
    function M.student_file()
        local hint = io.open(".chickadee_student_module", "r")
        if hint then
            local named = (hint:read("l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
            hint:close()
            local base = named:match("([^/\\]+)$") or named
            if base:match("%.lua$") and not RESERVED[base] and not is_test_file(base)
                and base ~= running_script() then
                local exists = io.open(base, "r")
                if exists then
                    exists:close()
                    return base
                end
            end
        end
        local fallback = io.open("solution.lua", "r")
        if fallback then
            fallback:close()
            return "solution.lua"
        end
        return nil
    end

    -- Load the submission into a fresh environment, so the tests see exactly what
    -- the student defined and nothing they defined can overwrite the harness.
    --
    -- Runtime errors are swallowed deliberately: a submission whose last top-level
    -- line raises has still defined every function above it, and those are what the
    -- tests are about. Compare test_runtime.R, which evaluates expression by
    -- expression for the same reason.
    function M.load_student()
        local file = M.student_file()
        if not file then
            M.errored("No Lua submission file was found to grade.")
        end
        local env = setmetatable({}, { __index = _G })
        local chunk, err = loadfile(file, "t", env)
        if not chunk then
            M.errored("Your submission (" .. file .. ") could not be parsed as Lua: " .. tostring(err))
        end
        pcall(chunk)
        return env
    end

    -- The submission split into notebook cells, for source-level checks.
    --
    -- `extractLua` writes an inert `-- ---- chickadee:cell N ----` comment ahead of
    -- each cell, which is what gives a source-level check cell granularity that
    -- plain concatenation loses. Same design as chickadee_student_cells in
    -- test_runtime.R, down to the marker text — only the comment leader differs,
    -- which is why both extractors share `extractWithCellMarkers`.
    --
    -- A submission that never came from a notebook (a hand-written .lua upload) has
    -- no markers, so the whole file comes back as one cell — file granularity,
    -- which is the honest answer for a file with no cells.
    function M.student_cells()
        local file = M.student_file()
        if not file then
            M.errored("No Lua submission file was found to grade.")
        end
        local handle = io.open(file, "r")
        if not handle then return {} end
        local text = handle:read("a") or ""
        handle:close()

        -- Split without inventing a trailing empty line. Appending "\n" and
        -- matching greedily does invent one, which put a stray newline on the end
        -- of the LAST cell only — so a `cellContains` check comparing exact source
        -- would behave differently for the final cell than for every other one.
        local lines = {}
        local pos = 1
        while pos <= #text do
            local nl = text:find("\n", pos, true)
            if nl then
                lines[#lines + 1] = text:sub(pos, nl - 1)
                pos = nl + 1
            else
                lines[#lines + 1] = text:sub(pos)
                pos = #text + 1
            end
        end

        local cells, current, seen_marker = {}, nil, false
        for _, line in ipairs(lines) do
            if line:match("^%-%- ---- chickadee:cell %d+ ----$") then
                if current then cells[#cells + 1] = table.concat(current, "\n") end
                current, seen_marker = {}, true
            elseif current then
                current[#current + 1] = line
            end
        end
        if current then cells[#cells + 1] = table.concat(current, "\n") end
        if not seen_marker then return { (text:gsub("\n$", "")) } end
        return cells
    end

    -- Fetch a function the student was asked to write; a clear error when it is
    -- missing or was bound to something that is not a function.
    function M.require_fn(env, name)
        local value = rawget(env, name)
        if type(value) ~= "function" then
            M.errored(string.format("Your submission must define a function called `%s()`.", name))
        end
        return value
    end

    return M
    """#

// MARK: - Octave runtime (mirrors Tools/runner-support/test_runtime.m)
//
// Byte-for-byte the canonical source in `Tools/runner-support/test_runtime.m`;
// `RuntimeSourceDriftTests` fails if the two diverge. The seed body mirrors
// `OctavePersonalizationRuntime.chickadeeSeedOctaveSource`, which the
// server-side expression driver composes, so the seed the driver binds and the
// seed a graded script reads are computed identically —
// `LanguagePipelineWalkTests` proves it by executing both.
let testRuntimeOctave =
    #"""
    % test_runtime.m — Chickadee Octave test helper library.
    % Obtain at the top of each Octave test script:
    %     chickadee = test_runtime();
    %
    % API (a struct of function handles — Octave's one-function-per-file rule
    % means separate helpers would each need their own file, and the runner
    % injects exactly one; a handle struct is the idiomatic single-file namespace):
    %   chickadee.passed(message)        — exit 0  (pass)
    %   chickadee.failed(message)        — exit 1  (fail)
    %   chickadee.errored(message)       — exit 2  (error)
    %   chickadee.label()                — the test's name, from program_name()
    %   chickadee.seed()                 — deterministic per-student integer seed
    %   chickadee.inputs()               — per-student inputs from _ck_inputs.m
    %   chickadee.student_file()         — the submitted .m file to grade
    %   chickadee.load_student()         — that file, loaded; returns an env struct
    %   chickadee.require_fn(env, name)  — a function the student had to write
    %   chickadee.has_var(env, name)     — is a workspace variable defined?
    %   chickadee.get_var(env, name)     — that variable's value
    %   chickadee.student_cells()        — submission split into notebook cells
    %   chickadee.format(value)          — one-line rendering, for failure messages
    %   chickadee.equal(a, b)            — value equality (see below)
    %   chickadee.unordered_equal(a, b)  — same elements, any order
    %
    % No package dependencies: JSON is hand-formatted, so this works on a bare
    % `octave-cli` install and inside the xeus-octave kernel alike.
    %
    % WHAT MAKES THIS FILE WORK IN BOTH RUNNERS. The native runner spawns
    % `octave-cli publictest_foo.m`, so the contract is a PROCESS contract:
    % exit() sets the status, program_name() names the script, getenv reads the
    % environment. A xeus-octave kernel has none of those — there is no process to
    % exit. The browser wrapper (Public/octave-grading-shared.js) re-creates the
    % contract inside one session by masking `exit`/`quit` and `program_name`
    % (command-line functions shadow builtins) before any script runs. This file
    % resolves all three by NAME at call time, so the masks are what its helpers
    % reach and the canonical copy stays byte-identical across both runners. Do
    % not replace exit() with a return-based protocol: under `octave-cli` that
    % would exit 0 for a failing test.
    %
    % THE SUBMISSION CONTRACT (the function-file/script-file question, decided):
    % a submission is loaded by evaluating its text prefixed with `1;`, which
    % forces Octave to read it as a SCRIPT whatever its first token is. That one
    % rule covers all three shapes a student can hand in:
    %   * a flattened notebook (statements + `function` definitions in any order),
    %   * a hand-written script,
    %   * a traditional one-function-per-file submission — the `1;` prefix stops
    %     Octave treating the FILE as the function, so the definition registers
    %     under its own name (`function r = classify(x)` defines `classify`
    %     whatever the file is called, where file-based resolution would have
    %     bound it to the filename).
    % Functions defined this way are command-line functions (exist() == 103),
    % fetched with str2func by require_fn. Variables land in the loader's private
    % workspace and are captured into the returned env struct. A runtime error
    % mid-file keeps everything defined before it, matching the R runtime's
    % expression-by-expression tolerance for the common shape (working functions
    % above, a stray failing call below); definitions after the error are lost,
    % which R's loader would have kept — a smaller promise, stated honestly.

    function M = test_runtime()
        M = struct( ...
            "passed", @ck_passed, ...
            "failed", @ck_failed, ...
            "errored", @ck_errored, ...
            "label", @ck_label, ...
            "seed", @ck_seed, ...
            "inputs", @ck_inputs, ...
            "student_file", @ck_student_file, ...
            "load_student", @ck_load_student, ...
            "require_fn", @ck_require_fn, ...
            "has_var", @ck_has_var, ...
            "get_var", @ck_get_var, ...
            "student_cells", @ck_student_cells, ...
            "format", @ck_format, ...
            "equal", @ck_equal, ...
            "unordered_equal", @ck_unordered_equal);
    end

    function s = ck_json_str(value)
        s = num2str(value);
        if ischar(value)
            s = value;
        end
        s = strrep(s, "\\", "\\\\");
        s = strrep(s, "\"", "\\\"");
        s = strrep(s, sprintf("\n"), "\\n");
        s = strrep(s, sprintf("\r"), "\\r");
        s = strrep(s, sprintf("\t"), "\\t");
        s = ["\"" s "\""];
    end

    % The test's name, as the grader labels it: the script filename without its
    % directory or extension. program_name() is what `octave-cli script.m`
    % populates and what the browser wrapper masks, so both runners answer the
    % same thing.
    function name = ck_label()
        path = program_name();
        [~, stem, ~] = fileparts(path);
        if isempty(stem)
            name = "test";
        else
            name = stem;
        end
    end

    % The script currently executing, with its extension — never mistakable for
    % the student's submission.
    function name = ck_running_script()
        path = program_name();
        [~, stem, ext] = fileparts(path);
        name = [stem ext];
    end

    function ck_emit(status, short_result, err)
        parts = { ...
            ["\"status\":" ck_json_str(status)], ...
            ["\"shortResult\":" ck_json_str(short_result)], ...
            ["\"test\":" ck_json_str(ck_label())]};
        if nargin >= 3 && !isempty(err)
            parts{end + 1} = ["\"error\":" ck_json_str(err)];
        end
        printf("{%s}\n", strjoin(parts, ","));
    end

    function ck_passed(message)
        if nargin < 1 || isempty(message)
            message = [ck_label() ": passed"];
        end
        ck_emit("pass", message);
        exit(0);
    end

    function ck_failed(message)
        if nargin < 1 || isempty(message)
            message = "failed";
        end
        ck_emit("fail", [ck_label() ": " message], message);
        exit(1);
    end

    function ck_errored(message)
        if nargin < 1 || isempty(message)
            message = "error";
        end
        ck_emit("error", [ck_label() ": " message], message);
        exit(2);
    end

    % --- Value formatting + comparison ------------------------------------------
    % Used by generated pattern-family tests (and available to hand-authored ones)
    % so failure messages read the same whatever produced them.

    % One-line, student-readable rendering — the Octave analogue of Python's
    % repr(). mat2str handles numeric/logical/char matrices; cells are shown one
    % level deep; a containers.Map shows its keys. Anything deeper or unprintable
    % is elided rather than recursed, so a cyclic struct cannot hang the grader.
    function s = ck_format(value, max_chars)
        if nargin < 2
            max_chars = 300;
        end
        s = ck_format_value(value);
        if numel(s) > max_chars
            s = [s(1:max_chars) " ..."];
        end
    end

    function s = ck_format_value(value)
        if ischar(value)
            s = ["\"" value "\""];
        elseif isa(value, "containers.Map")
            keys_list = value.keys();
            parts = cell(1, numel(keys_list));
            for i = 1:numel(keys_list)
                parts{i} = [keys_list{i} ": " ck_format_scalar(value(keys_list{i}))];
            end
            s = ["{" strjoin(parts, ", ") "}"];
        elseif iscell(value)
            parts = cell(1, numel(value));
            for i = 1:numel(value)
                parts{i} = ck_format_scalar(value{i});
            end
            s = ["{" strjoin(parts, ", ") "}"];
        elseif isnumeric(value) || islogical(value)
            s = mat2str(value);
        elseif isstruct(value)
            s = ["<struct with fields: " strjoin(fieldnames(value)', ", ") ">"];
        elseif is_function_handle(value)
            s = func2str(value);
        else
            s = ["<" class(value) ">"];
        end
    end

    function s = ck_format_scalar(value)
        if iscell(value) || isstruct(value)
            s = "{...}";
        else
            s = ck_format_value(value);
        end
    end

    % Value equality for generated tests. Built on isequaln — NOT isequal or a
    % string rendering — for three measured reasons:
    %   * a JSON null renders as NA (NaN-flavoured), and isequal(NA, NA) is
    %     false; isequaln treats missing-vs-missing as equal, which is what an
    %     authored [60, null, 20] case needs;
    %   * isequaln is type-blind across logical/int/double (isequal(1, true) and
    %     isequal(int32(1), 1.0) are both true), which matches how Octave's own
    %     `==` treats those values and what a student can observe;
    %   * it recurses into cells and containers.Map by content.
    % On top of isequaln, two Chickadee rules:
    %   * both-empty is equal whatever the container class: the literal renderer
    %     spells an empty JSON array `{}` (nothing says what it would have held),
    %     while a student computing an empty result usually produces `[]` — and
    %     `""` is the same absence in char form. isequal([], {}) is false, so
    %     without this rule every empty-expected case would fail on container
    %     kind, a distinction the assignment's JSON never drew.
    %   * numeric/logical values with equal element counts compare shape-blind
    %     (a(:) vs b(:)): the renderer emits JSON arrays as row vectors, while
    %     student arithmetic freely produces columns. R's `==`-with-all() does
    %     the same via recycling, so the two languages agree.
    function r = ck_equal(actual, expected)
        if isempty(actual) && isempty(expected)
            r = true;
            return;
        end
        numeric_like = @(v) (isnumeric(v) || islogical(v)) && !isa(v, "containers.Map");
        if numeric_like(actual) && numeric_like(expected)
            r = numel(actual) == numel(expected) && isequaln(actual(:), expected(:));
            return;
        end
        if iscell(actual) && iscell(expected)
            if numel(actual) != numel(expected)
                r = false;
                return;
            end
            for i = 1:numel(actual)
                if !ck_equal(actual{i}, expected{i})
                    r = false;
                    return;
                end
            end
            r = true;
            return;
        end
        r = isequaln(actual, expected);
    end

    % Order-insensitive comparison for the unordered_equality kind: the two
    % collections hold the same elements in any order. Defined by greedy pairwise
    % ck_equal — so it can NEVER disagree with `equal`, because it IS `equal`
    % applied pairwise (the F3 lesson from the Lua audit: a second, weaker notion
    % of equality beside the real one disagreed with it in both directions).
    % Numeric vectors and cell arrays are both accepted; each is viewed as a list
    % of elements first.
    function r = ck_unordered_equal(actual, expected)
        a = ck_as_element_list(actual);
        b = ck_as_element_list(expected);
        if isempty(a) || isempty(b)
            r = isempty(a) && isempty(b);
            return;
        end
        if numel(a) != numel(b)
            r = false;
            return;
        end
        used = false(1, numel(b));
        for i = 1:numel(a)
            matched = false;
            for j = 1:numel(b)
                if !used(j) && ck_equal(a{i}, b{j})
                    used(j) = true;
                    matched = true;
                    break;
                end
            end
            if !matched
                r = false;
                return;
            end
        end
        r = true;
    end

    function list = ck_as_element_list(value)
        if iscell(value)
            list = value(:)';
        elseif isnumeric(value) || islogical(value)
            list = num2cell(value(:)');
        else
            list = {value};
        end
    end

    % --- Per-student personalization primitives ---------------------------------
    % Mirror of OctavePersonalizationRuntime.chickadeeSeedOctaveSource in
    % Sources/Core — the server-side expression driver composes the same body, so
    % the seed it binds and the seed this reads are computed identically. Octave
    % has no bignum, so the 256-bit hex seed is folded with Horner's method modulo
    % 2^31-1 — the SAME reduction R and Lua use, so a student's seed is one number
    % whatever language the assignment is in. Every intermediate stays below 2^35,
    % safely inside a double.

    function value = ck_seed()
        raw = getenv("CHICKADEE_ASSIGNMENT_SEED");
        hex = lower(raw(isstrprop(raw, "xdigit")));
        if isempty(hex)
            value = 0;
            return;
        end
        modulus = 2147483647;
        acc = 0;
        for i = 1:numel(hex)
            acc = mod(acc * 16 + hex2dec(hex(i)), modulus);
        end
        value = acc;
    end

    % The per-student grading inputs the worker materialized into _ck_inputs.m
    % (two parallel cell arrays, names and values), as a containers.Map — or an
    % empty Map when none were delivered. The file is EVALUATED from its text
    % rather than run by name, so its leading-underscore filename never has to be
    % resolvable as a function and the same read works in both runners.
    function map = ck_inputs()
        map = containers.Map();
        if exist("_ck_inputs.m", "file") != 2
            return;
        end
        ck_input_names = {};
        ck_input_values = {};
        try
            eval(fileread("_ck_inputs.m"));
        catch
            return;
        end
        for i = 1:min(numel(ck_input_names), numel(ck_input_values))
            map(ck_input_names{i}) = ck_input_values{i};
        end
    end

    % --- Locating the student's submission --------------------------------------
    % Filenames Chickadee itself writes into the grading workspace are never the
    % student's submission.

    function r = ck_is_reserved(name)
        r = any(strcmp(name, {"test_runtime.m", "_ck_inputs.m"}));
    end

    function r = ck_is_test_file(name)
        r = !isempty(regexp(name, "^(publictest|releasetest|secrettest|studenttest)", "once"));
    end

    % The student's submitted Octave file: solution.m during validation, the
    % extracted notebook during grading. Prefers the runner's
    % `.chickadee_student_module` hint when it names an .m file actually present,
    % then falls back to scanning the working directory (readdir works in both
    % runners, unlike Lua whose standard library cannot list a directory).
    % Returns "" when nothing looks like a submission.
    function file = ck_student_file()
        file = "";
        hinted = "";
        if exist(".chickadee_student_module", "file") == 2
            try
                hinted = strtrim(fileread(".chickadee_student_module"));
            catch
                hinted = "";
            end
            newline_at = find(hinted == sprintf("\n"), 1);
            if !isempty(newline_at)
                hinted = strtrim(hinted(1:newline_at - 1));
            end
        end
        if !isempty(hinted)
            [~, stem, ext] = fileparts(hinted);
            base = [stem ext];
            if strcmpi(ext, ".m") && !ck_is_reserved(base) && !ck_is_test_file(base) ...
                && !strcmp(base, ck_running_script()) && exist(base, "file") == 2
                file = base;
                return;
            end
        end
        entries = sort(cellstr(readdir(pwd())));
        candidates = {};
        for i = 1:numel(entries)
            name = entries{i};
            [~, ~, ext] = fileparts(name);
            if !strcmpi(ext, ".m")
                continue;
            end
            if ck_is_reserved(name) || ck_is_test_file(name) || strcmp(name, ck_running_script())
                continue;
            end
            candidates{end + 1} = name;
        end
        if isempty(candidates)
            return;
        end
        if any(strcmp(candidates, "solution.m"))
            file = "solution.m";
            return;
        end
        file = candidates{1};
    end

    % Load the submission. See "THE SUBMISSION CONTRACT" in the header: the text
    % is evaluated with a `1;` prefix so every submission shape reads as a script,
    % its function definitions register under their own names, and its variables
    % land here — captured into the returned env struct. A runtime error mid-file
    % keeps everything defined before it.
    function env = ck_load_student()
        ck_file_ = ck_student_file();
        if isempty(ck_file_)
            ck_errored("No Octave submission file was found to grade.");
        end
        ck_text_ = fileread(ck_file_);
        env = struct("file", ck_file_, "vars", struct());
        try
            eval(["1;" sprintf("\n") ck_text_]);
        catch ck_err_
            % A parse error means nothing was defined; a runtime error partway is
            % the tolerated shape. Distinguishing them is not worth a parser: if
            % no function or variable materialised at all, report the message.
            ck_defined_ = setdiff(who(), ...
                {"ck_file_", "ck_text_", "ck_err_", "ck_defined_", "env"});
            if isempty(ck_defined_)
                ck_errored(["Your submission (" ck_file_ ") could not be run as Octave: " ...
                    ck_err_.message]);
            end
        end
        ck_names_ = setdiff(who(), {"ck_file_", "ck_text_", "ck_err_", "ck_defined_", "env"});
        for ck_i_ = 1:numel(ck_names_)
            env.vars.(ck_names_{ck_i_}) = eval(ck_names_{ck_i_});
        end
    end

    % Fetch a function the student was asked to write; a clear error when it is
    % missing or bound to something that is not callable. Checks the submission's
    % own variables first (a handle assigned with `f = @(x) ...`), then the
    % command-line functions its definitions registered.
    function fn = ck_require_fn(env, name)
        if isfield(env.vars, name)
            candidate = env.vars.(name);
            if is_function_handle(candidate)
                fn = candidate;
                return;
            end
            ck_errored(sprintf( ...
                "Your submission must define a function called `%s()` (found a %s).", ...
                name, class(candidate)));
        end
        kind = exist(name);
        if any(kind == [2, 3, 5, 103])
            fn = str2func(name);
            return;
        end
        ck_errored(sprintf("Your submission must define a function called `%s()`.", name));
    end

    function r = ck_has_var(env, name)
        r = isfield(env.vars, name);
    end

    function value = ck_get_var(env, name)
        value = env.vars.(name);
    end

    % The submission split into notebook cells, for source-level checks.
    % `extractOctave` writes an inert `% ---- chickadee:cell N ----` comment ahead
    % of each cell — same design as R and Lua, only the comment leader differs. A
    % submission that never came from a notebook has no markers, so the whole file
    % comes back as one cell: file granularity, the honest answer for a file with
    % no cells.
    function cells = ck_student_cells()
        file = ck_student_file();
        if isempty(file)
            ck_errored("No Octave submission file was found to grade.");
        end
        text = fileread(file);
        lines = strsplit(text, sprintf("\n"), "CollapseDelimiters", false);
        cells = {};
        current = {};
        seen_marker = false;
        started = false;
        for i = 1:numel(lines)
            line = lines{i};
            if !isempty(regexp(line, "^% ---- chickadee:cell [0-9]+ ----$", "once"))
                if started
                    cells{end + 1} = strjoin(current, sprintf("\n"));
                end
                current = {};
                started = true;
                seen_marker = true;
            elseif started
                current{end + 1} = line;
            end
        end
        if started
            cells{end + 1} = strjoin(current, sprintf("\n"));
        end
        if !seen_marker
            whole = text;
            if !isempty(whole) && whole(end) == sprintf("\n")
                whole = whole(1:end - 1);
            end
            cells = {whole};
            return;
        end
        for i = 1:numel(cells)
            cells{i} = regexprep(cells{i}, "\\s+$", "");
        end
    end
    """#

// MARK: - C++ runtime (mirrors Tools/runner-support/test_runtime.hpp)
//
// Byte-for-byte the canonical source in `Tools/runner-support/test_runtime.hpp`;
// `RuntimeSourceDriftTests` fails if the two drift. A HEADER rather than a
// module: C++ reaches other code at compile time, so the runtime is included
// into each generated test's single translation unit by the .sh wrapper's
// heredoc source.
let testRuntimeCpp =
    #"""
    // test_runtime.hpp — Chickadee's C++ grading runtime.
    //
    // The C++ member of the test_runtime family (.py/.R/.lua/.m), with the shape
    // the language dictates: a HEADER of templates rather than a loadable module,
    // because C++ reaches other code at compile time. A generated test forms one
    // translation unit: this header, then the student's file (copied by the
    // wrapper to .ck_solution.cpp, with `main` renamed so a main-bearing
    // submission still exposes its functions), then the test's own main().
    //
    // Everything here was measured before it was written — see
    // docs/cpp-support.md. The two decisions that came from measurement:
    //   * std::cmp_equal rejects bool BY DESIGN, so equality promotes bools
    //     explicitly; without that, a JSON `true` literal is three compile
    //     errors.
    //   * stdout capture is fd-level (dup2), not rdbuf: printf-using students
    //     must grade the same as cout-using ones.
    //
    // Outcome contract: pass/fail/error print a one-line shortResult JSON to
    // stdout and exit 0/1/2 — the ordinary shell-script contract, carried by the
    // binary the wrapper exec's.
    #pragma once
    #include <algorithm>
    #include <chrono>
    #include <cmath>
    #include <cstdio>
    #include <cstdlib>
    #include <fcntl.h>
    #include <fstream>
    #include <iostream>
    #include <limits>
    #include <map>
    #include <optional>
    #include <sstream>
    #include <string>
    #include <string_view>
    #include <type_traits>
    #include <unistd.h>
    #include <utility>
    #include <vector>

    namespace ck {

    // ---- JSON escaping for shortResult payloads ----
    inline std::string json_escape(const std::string& s) {
        std::string out;
        out.reserve(s.size() + 8);
        for (unsigned char c : s) {
            switch (c) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\n': out += "\\n"; break;
                case '\t': out += "\\t"; break;
                case '\r': out += "\\r"; break;
                default:
                    if (c < 0x20) {
                        char buf[8];
                        std::snprintf(buf, sizeof buf, "\\u%04x", c);
                        out += buf;
                    } else {
                        out += static_cast<char>(c);
                    }
            }
        }
        return out;
    }

    // ---- the shell contract's exit codes ----
    [[noreturn]] inline void passed(const std::string& msg) {
        std::cout << "{\"shortResult\": \"" << json_escape(msg) << "\"}\n";
        std::exit(0);
    }
    [[noreturn]] inline void failed(const std::string& msg) {
        std::cout << "{\"shortResult\": \"" << json_escape(msg) << "\"}\n";
        std::exit(1);
    }
    [[noreturn]] inline void errored(const std::string& msg) {
        std::cerr << msg << "\n";
        std::exit(2);
    }

    // ---- equal: the cross-type comparison surface ----
    //
    // The same equality decisions the other runtimes made, restated for a
    // statically-typed language: 1 == 1.0 == true across numeric kinds, strings
    // by value whatever their spelling (std::string, const char*, string_view),
    // containers elementwise with cross-element-type tolerance so the author's
    // vector<long long> matches the student's vector<int>.
    template <typename A, typename B>
    bool equal(const A& a, const B& b);

    template <typename A, typename B>
        requires(std::is_arithmetic_v<A> && std::is_arithmetic_v<B>)
    bool equal_impl(const A& a, const B& b, int) {
        if constexpr (std::is_floating_point_v<A> || std::is_floating_point_v<B>) {
            return static_cast<long double>(a) == static_cast<long double>(b);
        } else if constexpr (std::is_same_v<A, bool> || std::is_same_v<B, bool>) {
            // std::cmp_equal rejects bool by design; promote so true == 1 holds.
            return static_cast<long long>(a) == static_cast<long long>(b);
        } else {
            return std::cmp_equal(a, b);
        }
    }

    template <typename A, typename B>
        requires(std::is_convertible_v<A, std::string_view>
                 && std::is_convertible_v<B, std::string_view>)
    bool equal_impl(const A& a, const B& b, int) {
        return std::string_view(a) == std::string_view(b);
    }

    template <typename A, typename B>
    bool equal_impl(const std::vector<A>& a, const std::vector<B>& b, int) {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i)
            if (!equal(a[i], b[i])) return false;
        return true;
    }

    template <typename A, typename B>
    bool equal_impl(const std::map<std::string, A>& a, const std::map<std::string, B>& b, int) {
        if (a.size() != b.size()) return false;
        auto it = b.begin();
        for (const auto& [key, value] : a) {
            if (it->first != key || !equal(value, it->second)) return false;
            ++it;
        }
        return true;
    }

    // Fallback: same-type operator==; different unrelated types are not equal.
    template <typename A, typename B>
    bool equal_impl(const A& a, const B& b, long) {
        if constexpr (std::is_same_v<A, B>) {
            return a == b;
        } else {
            return false;
        }
    }

    template <typename A, typename B>
    bool equal(const A& a, const B& b) {
        return equal_impl(a, b, 0);
    }

    // approximateEquality's tolerance comparison.
    template <typename A, typename B>
    bool close(const A& a, const B& b, double tolerance) {
        return std::fabs(static_cast<double>(a) - static_cast<double>(b)) <= tolerance;
    }

    // unorderedEquality: pairwise-greedy over equal, multiset-correct, and
    // cross-element-type like everything else here.
    template <typename A, typename B>
    bool unordered_equal(const std::vector<A>& a, const std::vector<B>& b) {
        if (a.size() != b.size()) return false;
        std::vector<bool> used(b.size(), false);
        for (const auto& x : a) {
            bool matched = false;
            for (size_t j = 0; j < b.size(); ++j) {
                if (!used[j] && equal(x, b[j])) {
                    used[j] = true;
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
        }
        return true;
    }

    // ---- format: how a value appears in a shortResult ----
    inline std::string format(const std::string& v) { return "\"" + v + "\""; }
    inline std::string format(const char* v) { return format(std::string(v)); }
    inline std::string format(std::string_view v) { return format(std::string(v)); }
    inline std::string format(bool v) { return v ? "true" : "false"; }
    template <typename T>
        requires std::is_arithmetic_v<T>
    std::string format(T v) {
        std::ostringstream os;
        os << v;
        return os.str();
    }
    template <typename T>
    std::string format(const std::vector<T>& v) {
        std::string out = "[";
        for (size_t i = 0; i < v.size(); ++i) {
            if (i) out += ", ";
            out += format(v[i]);
        }
        return out + "]";
    }
    template <typename T>
    std::string format(const std::map<std::string, T>& m) {
        std::string out = "{";
        bool first = true;
        for (const auto& [key, value] : m) {
            if (!first) out += ", ";
            first = false;
            out += "\"" + key + "\": " + format(value);
        }
        return out + "}";
    }
    // Anything else: name the situation rather than guess a rendering.
    // Constrained away from everything the overloads above serve, or an `int`
    // would be ambiguous between this and the arithmetic template.
    template <typename T>
        requires(!std::is_arithmetic_v<std::decay_t<T>>
                 && !std::is_convertible_v<T, std::string_view>)
    std::string format(const T&) {
        return "(value)";
    }

    // ---- stdout capture for stdoutEquality ----
    //
    // fd-level (dup2 to a temp file), so printf AND std::cout are captured.
    // rdbuf-swapping misses printf, and a course cannot control which one a
    // student reaches for.
    class CaptureStdout {
        int saved_;
        static constexpr const char* path_ = ".ck_stdout_capture";

      public:
        CaptureStdout() {
            std::fflush(stdout);
            std::cout.flush();
            saved_ = dup(1);
            int tmp = open(path_, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            dup2(tmp, 1);
            // Qualified: inside namespace ck, a bare `close` is ck::close (the
            // tolerance comparison), not POSIX close(2).
            ::close(tmp);
        }
        std::string finish() {
            std::fflush(stdout);
            std::cout.flush();
            dup2(saved_, 1);
            ::close(saved_);
            std::ifstream in(path_);
            return std::string(
                (std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        }
    };

    // ---- exceptionExpected's trichotomy ----
    enum class ThrowOutcome { threwMatching, threwOther, returned };
    template <typename F>
    ThrowOutcome expect_throw(F&& f, std::string_view messageSubstring, std::string& what) {
        try {
            f();
            return ThrowOutcome::returned;
        } catch (const std::exception& e) {
            what = e.what();
            return what.find(messageSubstring) != std::string::npos ? ThrowOutcome::threwMatching
                                                                    : ThrowOutcome::threwOther;
        } catch (...) {
            what = "(a non-std exception)";
            return messageSubstring.empty() ? ThrowOutcome::threwMatching : ThrowOutcome::threwOther;
        }
    }

    // ---- returnTypeCheck's cross-language type names ----
    //
    // Matches the value's STATIC type against the authored, language-neutral
    // type name ("int", "float", "str", "bool", "list", "dict") — decltype-based,
    // no RTTI, so the answer is the overload-resolution truth rather than a
    // mangled runtime string.
    template <typename T>
    bool type_matches(std::string_view expected) {
        using D = std::decay_t<T>;
        if (expected == "bool") return std::is_same_v<D, bool>;
        if (expected == "int") return std::is_integral_v<D> && !std::is_same_v<D, bool>;
        if (expected == "float") return std::is_floating_point_v<D>;
        if (expected == "str")
            return std::is_same_v<D, std::string> || std::is_same_v<D, std::string_view>
                || std::is_same_v<D, const char*> || std::is_same_v<D, char*>;
        if (expected == "list") {
            if constexpr (requires { typename D::value_type; }) {
                return std::is_same_v<D, std::vector<typename D::value_type>>;
            } else {
                return false;
            }
        }
        if (expected == "dict") {
            if constexpr (requires {
                              typename D::key_type;
                              typename D::mapped_type;
                          }) {
                return std::is_same_v<
                    D, std::map<typename D::key_type, typename D::mapped_type>>;
            } else {
                return false;
            }
        }
        return false;
    }

    // The static type's human name for failure messages, best-effort.
    template <typename T>
    std::string type_name() {
        using D = std::decay_t<T>;
        if constexpr (std::is_same_v<D, bool>) return "bool";
        else if constexpr (std::is_integral_v<D>) return "int";
        else if constexpr (std::is_floating_point_v<D>) return "float";
        else if constexpr (std::is_same_v<D, std::string> || std::is_same_v<D, const char*>
                           || std::is_same_v<D, char*> || std::is_same_v<D, std::string_view>)
            return "str";
        else if constexpr (requires { typename D::mapped_type; }) return "dict";
        else if constexpr (requires { typename D::value_type; }) return "list";
        else return "(another type)";
    }

    }  // namespace ck
    """# + "\n"

// MARK: - Racket runtime (mirrors Tools/runner-support/test_runtime.rkt)
//
// Byte-for-byte the canonical source in `Tools/runner-support/test_runtime.rkt`;
// `runtimeHelpersMatchTheirCanonicalSource` fails if the two drift. A MODULE that
// `provide`s its helpers — the one Racket file in a grading workspace that can,
// since the student's own module is a teaching-language module and exports
// nothing (see the file's own header for what follows from that).
let testRuntimeRacket =
    #"""
    #lang racket/base
    ;; test_runtime.rkt — Chickadee's Racket grading runtime.
    ;;
    ;; The Racket member of the test_runtime family (.py/.R/.lua/.m/.hpp). Its shape
    ;; is dictated by one fact that no other language in the family has:
    ;;
    ;;   A STUDENT MODULE EXPORTS NOTHING.
    ;;
    ;; CS 135 and CS 115 submissions are HtDP teaching languages (`#lang htdp/bsl`
    ;; and friends), and such a module has no `provide` — so `(require "student.rkt")`
    ;; binds nothing at all. Everything below follows from working around that, and
    ;; each workaround was measured against a real `racket` before it was written,
    ;; because the obvious spelling fails in each case:
    ;;
    ;;   1. LOADING. `dynamic-require` the module for its side effect, then take
    ;;      `module->namespace` to reach its internal definitions. Requiring it
    ;;      normally yields an empty set of bindings, not an error — the silent kind.
    ;;
    ;;   2. DEFINEDNESS. Ask `namespace-mapped-symbols`, never
    ;;      `namespace-variable-value`. The latter returns its failure thunk for a
    ;;      perfectly good BSL binding (measured), so a defined function reads as
    ;;      missing and every case skips behind a guard that should have passed.
    ;;
    ;;   3. CALLING. Evaluate an APPLICATION FORM, never a bare identifier. BSL
    ;;      rejects a function reference outside operator position — the error reads
    ;;      "expected a function call, but there is no open parenthesis before this
    ;;      function" — so you cannot extract the procedure and apply it.
    ;;
    ;;   4. ARGUMENTS. Bind each value into the namespace and pass it BY NAME.
    ;;      Quoting is the natural spelling and BSL refuses it: `(quote (1 2 3))`
    ;;      fails with "expected the name of a symbol or () after the quote, but
    ;;      found a part". That is measured, and it would have broken silently for
    ;;      exactly the list-valued arguments a CS 135 assignment is made of.
    ;;
    ;; The payoff for all four: ONE generated test works unchanged against
    ;; `#lang htdp/bsl` and `#lang racket`, so the CS 135 and CS 136 dialects need
    ;; no separate authoring path.

    (require racket/list racket/string racket/path)

    (provide chickadee-load-student
             chickadee-defined?
             chickadee-call
             chickadee-passed
             chickadee-failed
             chickadee-errored
             chickadee-equal?
             chickadee-unordered-equal?
             chickadee-format
             chickadee-inputs
             chickadee-label
             chickadee-value
             chickadee-call/capture
             chickadee-type-name
             chickadee-stdout-matches?)

    ;; --- Test label ------------------------------------------------------------
    ;; The runner reads the label off the generated file's first `; Test:` line, and
    ;; results echo it back. Reading our own source keeps one source of truth.

    (define (chickadee-label)
      (define path (find-system-path 'run-file))
      (with-handlers ([exn:fail? (lambda (_) "test")])
        (define line
          (for/first ([l (in-lines (open-input-file (current-test-path)))]
                      #:when (regexp-match #rx"^;+ *Test:" l))
            l))
        (if line
            (string-trim (regexp-replace #rx"^;+ *Test: *" line ""))
            (path->string (file-name-from-path path)))))

    (define (current-test-path)
      (find-system-path 'run-file))

    ;; --- Result reporting ------------------------------------------------------
    ;; The shell-script contract: exit 0/1/2, and the LAST non-empty stdout line is
    ;; read as JSON. Detail goes to stderr, which the runner captures as longResult.

    (define (emit status short [err #f])
      (printf "{\"status\":~a,\"shortResult\":~a,\"test\":~a~a}\n"
              (json-string status)
              (json-string short)
              (json-string (chickadee-label))
              (if err (format ",\"error\":~a" (json-string err)) "")))

    ;; Hand-rolled rather than `json`'s `write-json`: this file is loaded by every
    ;; generated test, and the strings it emits are short. Escapes cover what a
    ;; failure message can actually contain.
    (define (json-string s)
      (define str (if (string? s) s (format "~a" s)))
      (string-append
       "\""
       (apply string-append
              (for/list ([ch (in-string str)])
                (cond [(char=? ch #\") "\\\""]
                      [(char=? ch #\\) "\\\\"]
                      [(char=? ch #\newline) "\\n"]
                      [(char=? ch #\return) "\\r"]
                      [(char=? ch #\tab) "\\t"]
                      [(char<? ch #\space) (format "\\u~a" (~hex (char->integer ch)))]
                      [else (string ch)])))
       "\""))

    (define (~hex n)
      (define s (number->string n 16))
      (string-append (make-string (max 0 (- 4 (string-length s))) #\0) s))

    (define (chickadee-passed [message #f])
      (emit "pass" (or message (format "~a: passed" (chickadee-label))))
      (exit 0))

    (define (chickadee-failed [message "failed"])
      (emit "fail" (format "~a: ~a" (chickadee-label) message) message)
      (eprintf "~a\n" message)
      (exit 1))

    (define (chickadee-errored [message "error"])
      (emit "error" (format "~a: ~a" (chickadee-label) message) message)
      (eprintf "~a\n" message)
      (exit 2))

    ;; --- Locating and loading the submission -----------------------------------

    ;; Names that are never the student's module.
    (define (reserved-name? base)
      (or (string=? base "test_runtime.rkt")
          (string=? base "_ck_inputs.rkt")
          (regexp-match? #rx"test" base)))

    ;; The runner writes `.chickadee_student_module` on every job. Unlike Lua, we
    ;; CAN list a directory, so a scan backs the hint up — same posture as R and
    ;; Python.
    (define (chickadee-student-file)
      (define hinted
        (and (file-exists? ".chickadee_student_module")
             (let ([named (string-trim (file->line ".chickadee_student_module"))])
               (and (not (string=? named ""))
                    (let ([base (path->string (file-name-from-path (string->path named)))])
                      (and (regexp-match? #rx"[.]rkt$" base)
                           (not (reserved-name? base))
                           (file-exists? base)
                           base))))))
      (or hinted
          (and (file-exists? "solution.rkt") "solution.rkt")
          (let ([candidates
                 (sort (for/list ([p (in-list (directory-list))]
                                  #:when (let ([b (path->string p)])
                                           (and (regexp-match? #rx"[.]rkt$" b)
                                                (not (reserved-name? b)))))
                         (path->string p))
                       string<?)])
            (and (pair? candidates) (first candidates)))))

    (define (file->line path)
      (call-with-input-file path (lambda (in) (or (read-line in) ""))))

    ;; Returns the submission's namespace. Errors (rather than fails) when there is
    ;; nothing to grade — a missing submission is not a wrong answer.
    (define (chickadee-load-student)
      (define file (chickadee-student-file))
      (unless file
        (chickadee-errored "No Racket submission file was found to grade."))
      (define complete (path->string (path->complete-path file)))
      (with-handlers
          ([exn:fail?
            (lambda (e)
              ;; A submission that does not compile is a FAILURE of the test, not a
              ;; runner error: the student's own syntax error is the finding.
              (chickadee-failed
               (format "Your submission could not be loaded: ~a" (exn-message e))))])
        (define mp `(file ,complete))
        (dynamic-require mp #f)
        (module->namespace mp)))

    ;; See note 2 in the header: this is the only definedness test that works for a
    ;; teaching-language module.
    (define (chickadee-defined? ns name)
      (and (memq name (namespace-mapped-symbols ns)) #t))

    ;; See notes 3 and 4: application form, arguments bound by name.
    (define (chickadee-call ns name args)
      (define arg-names
        (for/list ([i (in-range (length args))])
          (string->symbol (format "ck-arg~a" i))))
      (for ([n (in-list arg-names)] [v (in-list args)])
        (namespace-set-variable-value! n v #t ns))
      (eval (cons name arg-names) ns))

    ;; A module-level VALUE (not a function). Safe to evaluate bare: BSL's
    ;; operator-position restriction applies to procedures, not to data bindings —
    ;; `(define x 5)` then `x` is legal there. Used by `variableEquality`.
    (define (chickadee-value ns name)
      (eval name ns))

    ;; Calls the student's function with stdout captured, for `stdoutEquality`.
    ;; Returns (values printed-string result).
    (define (chickadee-call/capture ns name args)
      (define out (open-output-string))
      (define result (parameterize ([current-output-port out]) (chickadee-call ns name args)))
      (values (get-output-string out) result))

    ;; The neutral type names pattern families use, mapped onto Racket's predicates.
    ;; Racket has no "int" distinct from a whole flonum in the way Python does, so
    ;; `integer?` deliberately accepts 5.0 — a student who computed a whole number
    ;; by division has not made a type error.
    (define (chickadee-type-name v)
      (cond [(and (number? v) (integer? v)) "int"]
            [(number? v) "float"]
            [(string? v) "str"]
            [(boolean? v) "bool"]
            [(list? v) "list"]
            [(hash? v) "dict"]
            [else (format "~a" (let-values ([(t _) (values (object-name v) #f)]) (or t "value")))]))

    ;; --- Per-student inputs ----------------------------------------------------

    (define (chickadee-inputs)
      (if (file-exists? "_ck_inputs.rkt")
          (with-handlers ([exn:fail? (lambda (_) (hash))])
            (dynamic-require `(file ,(path->string (path->complete-path "_ck_inputs.rkt")))
                             'ck-inputs))
          (hash)))

    ;; --- Comparison ------------------------------------------------------------

    ;; `equal?` is WRONG for grading numbers: Racket distinguishes exact from
    ;; inexact, so `(equal? 25 25.0)` is #f and a student returning a flonum where
    ;; the expectation is an integer would be marked wrong for being right. `=`
    ;; compares across the exactness boundary, so numbers take that path.
    ;;
    ;; NaN matches NaN, matching Octave's `isequaln` posture: an expectation of NaN
    ;; is asking "is this not-a-number", and `=` alone answers #f to that.
    (define (chickadee-equal? a b)
      (cond
        [(and (real? a) (real? b))
         (cond [(and (nan? a) (nan? b)) #t]
               [(or (nan? a) (nan? b)) #f]
               [else (= a b)])]
        [(and (list? a) (list? b))
         (and (= (length a) (length b)) (andmap chickadee-equal? a b))]
        [(and (hash? a) (hash? b))
         (and (= (hash-count a) (hash-count b))
              (for/and ([(k v) (in-hash a)])
                (and (hash-has-key? b k) (chickadee-equal? v (hash-ref b k)))))]
        [(and (vector? a) (vector? b))
         (chickadee-equal? (vector->list a) (vector->list b))]
        [else (equal? a b)]))

    (define (nan? x) (and (real? x) (not (= x x))))

    ;; Order-insensitive comparison for `unorderedEquality`. Quadratic, which is the
    ;; right trade at test sizes and avoids requiring the elements be sortable.
    (define (chickadee-unordered-equal? a b)
      (and (list? a) (list? b)
           (= (length a) (length b))
           (let loop ([remaining b] [items a])
             (cond
               [(null? items) #t]
               [else
                (define idx
                  (for/first ([(v i) (in-indexed remaining)]
                              #:when (chickadee-equal? (car items) v))
                    i))
                (and idx
                     (loop (append (take remaining idx) (drop remaining (add1 idx)))
                           (cdr items)))]))))

    ;; Compares captured stdout against an expectation, ignoring surrounding
    ;; whitespace. A runtime helper rather than inline `string-trim` in the
    ;; generated test: generated tests are `#lang racket/base`, which does NOT
    ;; export `string-trim` — that lives in `racket/string`. Keeping the comparison
    ;; here means a generated case needs exactly one require.
    (define (chickadee-stdout-matches? printed expected)
      (define (trim s)
        (define str (if (string? s) s (format "~a" s)))
        (define chars (string->list str))
        (define (drop-ws lst) (if (and (pair? lst) (char-whitespace? (car lst))) (drop-ws (cdr lst)) lst))
        (list->string (reverse (drop-ws (reverse (drop-ws chars))))))
      (string=? (trim printed) (trim expected)))

    ;; One-line, student-readable rendering. `~s` is the write form, so strings keep
    ;; their quotes and a returned "25" is distinguishable from 25 in a failure
    ;; message — the whole point of showing the value back.
    (define (chickadee-format v)
      (format "~s" v))
    """# + "\n"

// MARK: - The per-language table

/// The runtime helper files a language's generated tests expect to find beside
/// them, keyed by the filename written into the grading workspace.
///
/// EXHAUSTIVE ON PURPOSE, and it is the whole point of this function existing.
/// The runner used to install these through five separate
/// `write<Language>RuntimeHelper` functions called from a hand-written list of
/// five, under a comment reading "one per language, unconditionally" — which was
/// true when it was written and silently false the moment a sixth language
/// existed. Racket shipped with a canonical `test_runtime.rkt`, no embed, no
/// write call and no test, so every generated Racket test's
/// `(require "test_runtime.rkt")` had nothing to find. Nothing failed; the list
/// was simply one shorter than `allCases`.
///
/// A dictionary rather than one filename plus one source because Python needs
/// two files: `sitecustomize.py` is loaded by the interpreter itself, not by the
/// test, and it is a runtime helper on exactly the same terms.
func runtimeHelperFiles(for language: AssignmentLanguage) -> [String: String] {
    switch language {
    case .python:
        return ["test_runtime.py": testRuntimePy, "sitecustomize.py": sitecustomizePy]
    case .r:
        return ["test_runtime.R": testRuntimeR]
    case .lua:
        return ["test_runtime.lua": testRuntimeLua]
    case .octave:
        return ["test_runtime.m": testRuntimeOctave]
    case .cpp:
        return ["test_runtime.hpp": testRuntimeCpp]
    case .racket:
        return ["test_runtime.rkt": testRuntimeRacket]
    }
}

/// Every language's runtime helpers, in one map. Duplicate filenames across
/// languages would silently drop one, so this traps rather than merging — the
/// inputs-filename uniqueness invariant applies here for the same reason.
func allRuntimeHelperFiles() -> [String: String] {
    var files: [String: String] = [:]
    for language in AssignmentLanguage.allCases {
        for (name, source) in runtimeHelperFiles(for: language) {
            precondition(
                files[name] == nil,
                "two languages both claim the runtime helper filename \(name)")
            files[name] = source
        }
    }
    return files
}
