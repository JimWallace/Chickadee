import Foundation
import RunnerCore

struct ScriptInvocation {
    let executableURL: URL
    let arguments: [String]
}

/// Where the runner image keeps matplotlib's prebuilt font cache (the
/// `Dockerfile` builds it once, after every font package is installed).
///
/// The sandbox gives each test script a fresh, empty `HOME` (#2252), so
/// matplotlib found no font cache and rebuilt it, by parsing every font on the
/// system, in every Python test whose submission imports `matplotlib.pyplot`.
/// That rebuild ran inside the test's time limit: about 90 ms of a 350 ms
/// `pyplot` import on the runner image (32 fonts), and seconds on a host with
/// many fonts. The bootstrap now copies the
/// prebuilt `fontlist-*.json` into the place matplotlib reads it from. A host
/// with no such directory (a runner outside the image) keeps the old
/// behaviour, and a cache that does not match the installed matplotlib is
/// rebuilt by matplotlib itself, so the copy can only skip work, never change a
/// result. The file is data that the image built, not code from a job, so it
/// keeps the isolation that the fresh `HOME` exists for.
let matplotlibFontCacheSource = "/usr/local/share/chickadee/matplotlib"

/// The bootstrap a Python test runs under. `fontCacheSource` is a parameter
/// only so a test can point it at a directory it made.
func pythonBootstrap(fontCacheSource: String = matplotlibFontCacheSource) -> String {
    """
    import builtins
    import runpy
    import sys


    def _ck_seed_matplotlib_font_cache(source):
        import os
        try:
            names = [n for n in os.listdir(source) if n.startswith("fontlist-") and n.endswith(".json")]
        except OSError:
            return
        if not names:
            return
        target = os.environ.get("MPLCONFIGDIR")
        if not target:
            home = os.path.expanduser("~")
            if sys.platform.startswith(("linux", "freebsd")):
                cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(home, ".cache")
                target = os.path.join(cache, "matplotlib")
            else:
                target = os.path.join(home, ".matplotlib")
        try:
            os.makedirs(target, exist_ok=True)
            for name in names:
                dest = os.path.join(target, name)
                if os.path.exists(dest):
                    continue
                with open(os.path.join(source, name), "rb") as src, open(dest, "wb") as out:
                    out.write(src.read())
        except OSError:
            pass


    _ck_seed_matplotlib_font_cache(\(pythonStringLiteral(fontCacheSource)))
    del _ck_seed_matplotlib_font_cache

    import test_runtime as _tr

    builtins.passed = _tr.passed
    builtins.failed = _tr.failed
    builtins.errored = _tr.errored
    builtins.require_function = _tr.require_function

    _student_module = _tr.load_student_module()
    builtins.student_module = _student_module
    if _student_module is not None:
        for _name, _value in vars(_student_module).items():
            if _name.startswith("_"):
                continue
            if callable(_value) and not hasattr(builtins, _name):
                setattr(builtins, _name, _value)

    # Shift sys.argv so sys.argv[0] is the script path, matching the behaviour of
    # a direct `python3 script.py` invocation.  Test frameworks that inspect
    # sys.argv[0] to locate the test file (e.g. the Marmoset-era chickadee.py
    # helper) break when sys.argv[0] is left as '-c'.
    sys.argv = sys.argv[1:]

    # A SystemExit raised in the submission's own code is reported as an error,
    # not as the test's status. The check is `_check_submission_exit` in
    # test_runtime.py, which the browser grader calls too
    # (Public/python-grading-shared.js), so the two agree by construction.
    try:
        runpy.run_path(sys.argv[0], run_name="__main__")
    except SystemExit as _ck_exit:
        _tr._check_submission_exit(_ck_exit, sys.argv[0])
        raise
    """
}

/// A Python string literal for `value`, which is a path the runner chose.
private func pythonStringLiteral(_ value: String) -> String {
    let escaped =
        value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

/// Built once: the bootstrap is the same for every Python test.
private let defaultPythonBootstrap = pythonBootstrap()

func pythonInvocation(for script: URL, fontCacheSource: String? = nil) -> ScriptInvocation {
    let bootstrap = fontCacheSource.map { pythonBootstrap(fontCacheSource: $0) } ?? defaultPythonBootstrap
    return ScriptInvocation(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", "-c", bootstrap, script.path]
    )
}

private func envInvocation(interpreter: String, script: URL) -> ScriptInvocation {
    ScriptInvocation(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [interpreter, script.path]
    )
}

private func shInvocation(for script: URL) -> ScriptInvocation {
    ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
}

/// Build the subprocess invocation for a test script. Classification (the
/// drift-prone "which interpreter?" decision) lives in RunnerCore and is shared
/// with the browser runner; this maps the interpreter to a concrete command and
/// owns the substrate-only bits (reading the file, the executable-bit fallback).
func scriptInvocation(for script: URL) -> ScriptInvocation {
    // Leading source for shebang / content classification (substrate I/O).
    // Bounded read: only the first 2 KB matter, so don't pull a large support
    // file fully into memory just to classify it.
    let source: String
    if let handle = try? FileHandle(forReadingFrom: script) {
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 2048)
        source = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    } else {
        source = ""
    }

    switch classifyScriptInterpreter(name: script.lastPathComponent, source: source) {
    case .python: return pythonInvocation(for: script)
    case .sh: return shInvocation(for: script)
    case .bash: return envInvocation(interpreter: "bash", script: script)
    case .zsh: return envInvocation(interpreter: "zsh", script: script)
    case .ruby: return envInvocation(interpreter: "ruby", script: script)
    case .perl: return envInvocation(interpreter: "perl", script: script)
    case .node: return envInvocation(interpreter: "node", script: script)
    case .php: return envInvocation(interpreter: "php", script: script)
    case .rscript: return envInvocation(interpreter: "Rscript", script: script)
    case .lua: return envInvocation(interpreter: "lua", script: script)
    // `octave-cli`, not `octave`: the same binary set minus any attempt to
    // reach a display. The package that ships it is `octave` (there is no
    // CLI-only Debian package).
    case .octave: return envInvocation(interpreter: "octave-cli", script: script)
    // Interpreted and needing no wrapper: `racket file.rkt` runs a generated
    // test directly under the ordinary shell-script exit-code contract.
    // Without this arm a `.rkt` classified `.unknown`, fell through to
    // `/bin/sh`, and exited 2 on its own leading `;` — every generated Racket
    // test reporting `error`, in the only grading path an upload-only language
    // has.
    case .racket: return envInvocation(interpreter: "racket", script: script)
    // `java Foo.java` — single-file source mode (Java 11+), which compiles the
    // file in memory and runs it. This serves a HAND-WRITTEN `.java` suite
    // entry; Chickadee's generated Java cases are `.sh` wrappers and never
    // arrive here, because source mode compiles exactly ONE file and would see
    // neither the student's class nor `test_runtime.java`.
    case .java: return envInvocation(interpreter: "java", script: script)
    case .unknown:
        if FileManager.default.isExecutableFile(atPath: script.path) {
            return ScriptInvocation(executableURL: script, arguments: [])
        }
        return shInvocation(for: script)  // extensionless shell-script fallback
    }
}
