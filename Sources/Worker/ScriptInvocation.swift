import Foundation
import RunnerCore

struct ScriptInvocation {
    let executableURL: URL
    let arguments: [String]
}

private let pythonBootstrap = """
    import builtins
    import os
    import runpy
    import sys

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

    # A test's result is its exit status, and the submission runs inside the
    # test's process. A `SystemExit` raised in the submission's own code --
    # `sys.exit(0)` from a function the test calls, or at the top level of a
    # notebook the test runs -- would otherwise end the test with the
    # submission's status, and status 0 reads as a pass. Exits from the test
    # itself and from passed/failed/errored are left alone. This does not stop
    # a determined submission (docs/grading-integrity.md, phase 2).
    # The runtime's own list of student files, loaded or not: a submission
    # whose import failed is still run again, as a script, by the notebook
    # checks that read its executed state (`student_main_state`).
    def _ck_submission_files():
        return {os.path.realpath(str(_path)) for _path in _tr._ordered_student_files()}

    def _ck_raised_in_submission(exit_request):
        files = _ck_submission_files()
        frame = exit_request.__traceback__
        while frame is not None:
            if os.path.realpath(frame.tb_frame.f_code.co_filename) in files:
                return True
            frame = frame.tb_next
        return False

    try:
        runpy.run_path(sys.argv[0], run_name="__main__")
    except SystemExit as _ck_exit:
        if _ck_raised_in_submission(_ck_exit):
            _tr.errored(f"the submission ended the test (SystemExit: {_ck_exit.code!r})")
        raise
    """

private func pythonInvocation(for script: URL) -> ScriptInvocation {
    ScriptInvocation(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", "-c", pythonBootstrap, script.path]
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
