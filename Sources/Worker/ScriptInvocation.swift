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

func scriptInvocation(for script: URL) -> ScriptInvocation {
    let ext = script.pathExtension.lowercased()
    if let invocation = invocationForKnownExtension(ext, script: script) {
        return invocation
    }
    return invocationForUnknownExtension(script: script)
}

/// Maps a lowercased file extension to a known interpreter invocation.
/// Returns nil for extensions that need shebang/content-based detection.
private func invocationForKnownExtension(_ ext: String, script: URL) -> ScriptInvocation? {
    switch ext {
    case "sh":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
    case "bash":
        return envInvocation(interpreter: "bash", script: script)
    case "zsh":
        return envInvocation(interpreter: "zsh", script: script)
    case "py":
        return pythonInvocation(for: script)
    case "rb":
        return envInvocation(interpreter: "ruby", script: script)
    case "pl":
        return envInvocation(interpreter: "perl", script: script)
    case "js":
        return envInvocation(interpreter: "node", script: script)
    case "php":
        return envInvocation(interpreter: "php", script: script)
    case "r":
        return envInvocation(interpreter: "Rscript", script: script)
    default:
        return nil
    }
}

/// Resolves an invocation for a script without a recognised extension by
/// consulting the shebang, sniffing for Python-looking content, and finally
/// falling back to executable bit / `/bin/sh`.
private func invocationForUnknownExtension(script: URL) -> ScriptInvocation {
    if let shebang = shebangLine(for: script),
        let invocation = invocationFromShebang(shebang, script: script)
    {
        return invocation
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

/// Matches a normalised (lowercased) shebang line against the interpreters
/// we recognise. Returns nil if none match.
private func invocationFromShebang(_ shebang: String, script: URL) -> ScriptInvocation? {
    if shebang.contains("python") {
        return pythonInvocation(for: script)
    }
    if shebang.contains("node") || shebang.contains("javascript") {
        return envInvocation(interpreter: "node", script: script)
    }
    if shebang.contains("ruby") {
        return envInvocation(interpreter: "ruby", script: script)
    }
    if shebang.contains("perl") {
        return envInvocation(interpreter: "perl", script: script)
    }
    if shebang.contains("bash") {
        return envInvocation(interpreter: "bash", script: script)
    }
    if shebang.contains("zsh") {
        return envInvocation(interpreter: "zsh", script: script)
    }
    if shebang.contains("sh") {
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
    }
    return nil
}

private func envInvocation(interpreter: String, script: URL) -> ScriptInvocation {
    ScriptInvocation(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [interpreter, script.path]
    )
}

private func shebangLine(for script: URL) -> String? {
    guard let data = try? Data(contentsOf: script),
        let text = String(data: data.prefix(512), encoding: .utf8)
    else {
        return nil
    }
    let normalizedText =
        text
        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = normalizedText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(
        String.init)
    guard let firstLine, firstLine.hasPrefix("#!") else { return nil }
    return firstLine.lowercased()
}

private func looksLikePythonScript(_ script: URL) -> Bool {
    guard let data = try? Data(contentsOf: script),
        let text = String(data: data.prefix(2048), encoding: .utf8)
    else {
        return false
    }
    let lines =
        text
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
