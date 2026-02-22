import Foundation

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

runpy.run_path(sys.argv[1], run_name="__main__")
"""

private func pythonInvocation(for script: URL) -> ScriptInvocation {
    ScriptInvocation(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", "-c", pythonBootstrap, script.path]
    )
}

func scriptInvocation(for script: URL) -> ScriptInvocation {
    let ext = script.pathExtension.lowercased()
    switch ext {
    case "sh":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
    case "bash":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["bash", script.path])
    case "zsh":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["zsh", script.path])
    case "py":
        return pythonInvocation(for: script)
    case "rb":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["ruby", script.path])
    case "pl":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["perl", script.path])
    case "js":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", script.path])
    case "php":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["php", script.path])
    default:
        if let shebang = shebangLine(for: script) {
            if shebang.contains("python") {
                return pythonInvocation(for: script)
            }
            if shebang.contains("node") || shebang.contains("javascript") {
                return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", script.path])
            }
            if shebang.contains("ruby") {
                return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["ruby", script.path])
            }
            if shebang.contains("perl") {
                return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["perl", script.path])
            }
            if shebang.contains("bash") {
                return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["bash", script.path])
            }
            if shebang.contains("zsh") {
                return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["zsh", script.path])
            }
            if shebang.contains("sh") {
                return ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
            }
        }

        if looksLikePythonScript(script) {
            return pythonInvocation(for: script)
        }

        if FileManager.default.isExecutableFile(atPath: script.path) {
            return ScriptInvocation(executableURL: script, arguments: [])
        }
        // Fallback for extension-less shell scripts.
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
    }
}

private func shebangLine(for script: URL) -> String? {
    guard let data = try? Data(contentsOf: script),
          let text = String(data: data.prefix(512), encoding: .utf8) else {
        return nil
    }
    let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    guard let firstLine, firstLine.hasPrefix("#!") else { return nil }
    return firstLine.lowercased()
}

private func looksLikePythonScript(_ script: URL) -> Bool {
    guard let data = try? Data(contentsOf: script),
          let text = String(data: data.prefix(2048), encoding: .utf8) else {
        return false
    }
    let lines = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .prefix(5)

    guard !lines.isEmpty else { return false }
    return lines.contains { line in
        line.hasPrefix("import ")
            || line.hasPrefix("from ")
            || line.hasPrefix("def ")
            || line.hasPrefix("class ")
            || line.hasPrefix("if __name__ == ")
    }
}
