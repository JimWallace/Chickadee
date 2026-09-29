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
// call sites compared to UnsandboxedScriptRunner. The sandbox is entirely a
// matter of which executable leads the argument vector — the launch, capture,
// and time-limit machinery is the shared one in ScriptExecution.swift.

import Core
import Foundation

struct SandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput {
        await executeScriptLaunch(
            sandboxedLaunch(script: script, workDir: workDir, env: env),
            workDir: workDir,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch sandboxed script"
        )
    }
}

// MARK: - Startup probe

extension SandboxedScriptRunner {

    /// What an operator can do when the probe fails. It depends on the platform,
    /// because each sandbox is refused for a different reason.
    static var probeFailureAdvice: String {
        #if os(Linux)
        return "A container that drops capabilities or uses the default seccomp profile "
            + "refuses user namespaces. Remove --sandbox, or allow them."
        #elseif os(macOS)
        return "sandbox-exec cannot start inside another sandbox. "
            + "Remove --sandbox, or start the runner outside the sandbox."
        #else
        return "This platform has no sandbox. Remove --sandbox."
        #endif
    }

    /// Checks that this host can start the sandbox, by running a command that
    /// does nothing inside the same wrapper a real job uses.
    ///
    /// Returns `nil` when the sandbox works. Otherwise it returns the reason,
    /// for the operator. A container that drops capabilities or uses the
    /// default seccomp profile refuses `unshare`. Without this check, every
    /// job would fail on that refusal. The failure would look like a broken
    /// test script, not a broken runner.
    static func probe(workDir: URL) async -> String? {
        let output = await executeScriptLaunch(
            sandboxWrap(
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 0"],
                workDir: workDir,
                environment: mergedScriptEnvironment(overrides: [:])),
            workDir: workDir,
            timeLimitSeconds: 10,
            launchErrorPrefix: "Failed to launch sandbox probe")
        guard output.exitCode != 0 else { return nil }
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "probe exited with code \(output.exitCode)" : detail
    }
}

// MARK: - Platform-specific sandbox setup

private func sandboxedLaunch(script: URL, workDir: URL, env: [String: String]) -> ScriptLaunch {
    let invocation = scriptInvocation(for: script)
    return sandboxWrap(
        executablePath: invocation.executableURL.path,
        arguments: invocation.arguments,
        workDir: workDir,
        environment: mergedScriptEnvironment(overrides: env))
}

/// Puts the platform's sandbox launcher in front of a command. The one place
/// that decides how a command is sandboxed, so the probe and real jobs cannot
/// use different wrappers.
private func sandboxWrap(
    executablePath: String,
    arguments commandArguments: [String],
    workDir: URL,
    environment: [String: String]
) -> ScriptLaunch {

    #if os(Linux)
    return ScriptLaunch(
        executablePath: "/usr/bin/unshare",
        arguments: [
            "--fork",
            "--kill-child",
            "--user",
            "--net",
            "--map-root-user",
            executablePath,
        ] + commandArguments,
        env: environment
    )
    #elseif os(macOS)
    return ScriptLaunch(
        executablePath: "/usr/bin/sandbox-exec",
        arguments: ["-p", macOSSandboxProfile(workDir: workDir), executablePath]
            + commandArguments,
        env: environment
    )
    #else
    // Fallback: unsandboxed (unknown platform). Matches UnsandboxedScriptRunner
    // behaviour so the worker remains functional on unexpected targets.
    return ScriptLaunch(
        executablePath: executablePath,
        arguments: commandArguments,
        env: environment
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
