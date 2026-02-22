import inspect
import importlib.util
import json
import traceback
from pathlib import Path
from typing import Dict, List, Optional


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
    _emit({
        "shortResult": f"{label}: failed",
        "status": "fail",
        "test": label,
        "error": message,
    })
    raise SystemExit(1)


def errored(message: str = "error", err: Optional[Exception] = None):
    label = _first_comment_label()
    payload = {
        "shortResult": f"{label}: error",
        "status": "error",
        "test": label,
        "error": message,
    }
    if err is not None:
        payload["exception"] = repr(err)
        payload["traceback"] = traceback.format_exc()
    _emit(payload)
    raise SystemExit(2)


def _candidate_student_files() -> List[Path]:
    cwd = Path(".")
    files = []
    for p in sorted(cwd.glob("*.py")):
        name = p.name
        if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py"}:
            continue
        if name.startswith("publictest_") or name.startswith("secrettest_"):
            continue
        files.append(p)
    return files


def load_student_module():
    for path in _candidate_student_files():
        try:
            spec = importlib.util.spec_from_file_location(f"student_{path.stem}", path)
            if spec is None or spec.loader is None:
                continue
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        except Exception:
            continue
    return None


def require_function(name: str):
    module = load_student_module()
    if module is None:
        errored("Could not load a student Python module from submission.")
    fn = getattr(module, name, None)
    if fn is None or not callable(fn):
        errored(f"Required function '{name}' was not found or is not callable.")
    return fn
