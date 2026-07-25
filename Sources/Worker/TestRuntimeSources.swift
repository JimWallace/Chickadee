// Worker/TestRuntimeSources.swift
//
// Inline copies of the Python and R test helper libraries injected into
// each test working directory by the runner before execution.
//
// Canonical sources (kept in sync manually):
//   Tools/runner-support/test_runtime.py
//   Tools/runner-support/test_runtime.R

import Core

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
