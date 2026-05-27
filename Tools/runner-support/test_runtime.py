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
    # Rich multi-line messages are printed to stdout so they land in the
    # outcome's longResult.  The JSON footer below remains the last line and
    # is stripped by the runner.  Skip the print when the caller gave no
    # detail beyond the default placeholder.
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
    # Introspectable student source (real module-level defs, side-effects
    # quarantined into `if __name__`) for AST / source-property checks. The
    # grading workspace writes it to a sidecar named by the
    # `.chickadee_student_source` hint (both runners share one extractor);
    # falls back to inspect.getsource on the loaded module.
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
        # Built-ins / C functions may not expose a signature; skip the check.
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
