import Foundation

struct ScriptInvocation {
    let executableURL: URL
    let arguments: [String]
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
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["python3", script.path])
    case "rb":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["ruby", script.path])
    case "pl":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["perl", script.path])
    case "js":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", script.path])
    case "php":
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["php", script.path])
    default:
        if FileManager.default.isExecutableFile(atPath: script.path) {
            return ScriptInvocation(executableURL: script, arguments: [])
        }
        // Fallback for extension-less shell scripts.
        return ScriptInvocation(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path])
    }
}
