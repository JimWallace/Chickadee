// Worker/SandboxedScriptRunner.swift
//
// Sandboxed subprocess execution.
//
// On Linux  — uses `unshare --user --net --map-root-user` to run the script
//             inside a private user namespace (no real privileges) and a
//             private network namespace (no outbound connectivity).
//
// On macOS  — uses `sandbox-exec -p <profile>` to enforce a TCC-level policy:
//             deny all network, allow file-reads from the system prefix, allow
//             file-writes only inside the working directory.

import Foundation

struct SandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        let invocation = sandboxedInvocation(for: script, workDir: workDir)
        return await executeScript(
            configuration: invocation,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch sandboxed script"
        )
    }
}

// MARK: - Platform-specific sandbox setup

private func sandboxedInvocation(for script: URL, workDir: URL) -> SubprocessConfiguration {
    let invocation = scriptInvocation(for: script)
#if os(macOS)
    let profile = macOSSandboxProfile(workDir: workDir)
    return configuredSubprocess(
        executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
        arguments: ["-p", profile, invocation.executableURL.path] + invocation.arguments,
        workDir: workDir,
        isolatesProcessTreeForTimeouts: true
    )
#elseif os(Linux)
    return configuredSubprocess(
        executableURL: URL(fileURLWithPath: "/usr/bin/unshare"),
        arguments: ["--user", "--net", "--map-root-user", invocation.executableURL.path] + invocation.arguments,
        workDir: workDir,
        isolatesProcessTreeForTimeouts: true
    )
#else
    return configuredSubprocess(
        executableURL: invocation.executableURL,
        arguments: invocation.arguments,
        workDir: workDir,
        isolatesProcessTreeForTimeouts: true
    )
#endif
}

// MARK: - macOS sandbox profile

#if os(macOS)
private func macOSSandboxProfile(workDir: URL) -> String {
    // Policy intent:
    //   • Read the entire filesystem (system libs, JDK/Python runtimes, etc.)
    //   • Write only inside the working directory and /dev/null
    //   • Deny all network access (remote ip, tcp, udp)
    //   • Allow process execution and forking (needed to run sub-commands)
    //
    // Resolve symlinks so that the sandbox path matches what the kernel sees.
    // On macOS, FileManager.temporaryDirectory returns /var/folders/… which is
    // a symlink to /private/var/folders/…; URL.resolvingSymlinksInPath() does
    // not traverse /var → /private/var, so we call POSIX realpath(3) directly.
    let wd: String = workDir.path.withCString { ptr in
        guard let buf = Darwin.realpath(ptr, nil) else { return workDir.path }
        defer { free(buf) }
        return String(cString: buf)
    }
    return """
    (version 1)
    (deny default)
    (allow file-read* (subpath "/"))
    (allow file-write*
        (subpath "\(wd)")
        (literal "/dev/null")
        (literal "/dev/stdout")
        (literal "/dev/stderr"))
    (allow process-exec process-fork)
    (allow signal)
    (allow sysctl-read)
    (allow mach-lookup)
    (deny network* (remote ip))
    """
}
#endif
