// Worker/SandboxedScriptRunner.swift
//
// Phase 4: sandboxed subprocess execution.
//
// On Linux  — uses `unshare --user --net --map-root-user` to run the script
//             inside a private user namespace (no real privileges) and a
//             private network namespace (no outbound connectivity).
//
// On macOS  — uses `sandbox-exec -p <profile>` to enforce a TCC-level policy:
//             deny all network, allow file-reads from the system prefix, allow
//             file-writes only inside the working directory.
//
// Callers interact through the ScriptRunner protocol; no change is needed at
// call sites compared to UnsandboxedScriptRunner.

import Foundation

struct SandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        let proc = Process()
        let usesSeparateProcessGroup = configureSandboxedProcess(proc, script: script, workDir: workDir)

        return await executeScriptProcess(
            proc,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch sandboxed script",
            usesSeparateProcessGroup: usesSeparateProcessGroup
        )
    }
}

// MARK: - Platform-specific sandbox setup

private func configureSandboxedProcess(_ proc: Process, script: URL, workDir: URL) -> Bool {
    let invocation = scriptInvocation(for: script)
#if os(macOS)
    let profile = macOSSandboxProfile(workDir: workDir)
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    proc.arguments = ["-p", profile, invocation.executableURL.path] + invocation.arguments
    proc.currentDirectoryURL = workDir
    return false
#elseif os(Linux)
    // unshare --user  : new user namespace — current UID maps to root inside
    // unshare --net   : new network namespace — only loopback, no external routes
    // --map-root-user : write uid_map/gid_map automatically (requires no extra
    //                   privileges on kernels with unprivileged_userns_clone=1)
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [
        "setsid",
        "/usr/bin/unshare",
        "--user",
        "--net",
        "--map-root-user",
        invocation.executableURL.path
    ] + invocation.arguments
    proc.currentDirectoryURL = workDir
    return true
#else
    // Fallback: unsandboxed (unknown platform). Matches UnsandboxedScriptRunner
    // behaviour so the worker remains functional on unexpected targets.
    proc.executableURL = invocation.executableURL
    proc.arguments = invocation.arguments
    proc.currentDirectoryURL = workDir
    return false
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
