import Foundation
import RunnerCore

struct ScriptInvocation {
    let executableURL: URL
    let arguments: [String]
}

private let pythonBootstrap = """
    import builtins
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
    runpy.run_path(sys.argv[0], run_name="__main__")
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
    let source: String
    if let data = try? Data(contentsOf: script) {
        source = String(data: data.prefix(2048), encoding: .utf8) ?? ""
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
    case .unknown:
        if FileManager.default.isExecutableFile(atPath: script.path) {
            return ScriptInvocation(executableURL: script, arguments: [])
        }
        return shInvocation(for: script)  // extensionless shell-script fallback
    }
}
