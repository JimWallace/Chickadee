// Worker/TestRuntimeSources.swift
//
// Inline copies of the Python and R test helper libraries injected into
// each test working directory by the runner before execution.
//
// Canonical sources (kept in sync manually):
//   Tools/runner-support/test_runtime.py
//   Tools/runner-support/test_runtime.R

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
            if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py"}:
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


    def student_source() -> str:
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
let testRuntimeR = #"""
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
        x <- gsub("\\\\", "\\\\\\\\", x, fixed = TRUE)
        x <- gsub('"',    '\\\\"',    x, fixed = TRUE)
        x <- gsub("\n",   "\\\\n",    x, fixed = TRUE)
        x <- gsub("\r",   "\\\\r",    x, fixed = TRUE)
        x <- gsub("\t",   "\\\\t",    x, fixed = TRUE)
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
    """#
