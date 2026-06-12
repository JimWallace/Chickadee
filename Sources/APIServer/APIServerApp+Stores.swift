// APIServer/APIServerApp+Stores.swift
//
// Configuration struct + actor-backed stores (security, worker secret,
// worker activity, local-runner autostart, local-runner manager) +
// the secret-resolution helpers used by APIServerApp.configure.
// Split from APIServerApp.swift for navigability.

import CSRF
import Core
import Fluent
import Foundation
import Leaf
import Vapor

// `AppSecurityConfiguration` lives in `Configuration/SecurityConfig.swift`
// alongside the other AppConfig substructs.

actor WorkerSecretStore {
    private var runtimeOverride: String?

    init(initialOverride: String? = nil) {
        self.runtimeOverride = initialOverride
    }

    func setRuntimeOverride(_ secret: String?) {
        runtimeOverride = secret
    }

    func runtimeOverrideValue() -> String? {
        runtimeOverride
    }

    func effectiveSecret() -> String? {
        runtimeOverride ?? runnerSharedSecretFromEnvironment()
    }
}

struct WorkerActivitySnapshot: Sendable {
    let workerID: String
    let lastActive: Date
    let hostname: String
    let runnerVersion: String
    let maxConcurrentJobs: Int
    let activeJobs: Int
    let lastPollAt: Date?
    let lastHeartbeatAt: Date?
    let serverAssignedJobCountSinceStart: Int
}

actor WorkerActivityStore {
    private struct Entry: Sendable {
        let lastSeen: Date
        let hostname: String
        let runnerVersion: String
        let maxConcurrentJobs: Int
        let activeJobs: Int
        let lastPollAt: Date?
        let lastHeartbeatAt: Date?
        let serverAssignedJobCountSinceStart: Int
    }
    private var entries: [String: Entry] = [:]

    /// Record activity for `workerID`. Empty/zero values for `hostname`,
    /// `runnerVersion`, and `maxConcurrentJobs` are treated as "no update" —
    /// the existing values are preserved so that HMAC middleware keep-alive
    /// touches do not clobber fields set by the job-request body handler.
    func markActive(
        workerID: String,
        hostname: String,
        runnerVersion: String = "",
        maxConcurrentJobs: Int = 0,
        activeJobs: Int? = nil,
        lastPollAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        at date: Date = Date()
    ) {
        guard !workerID.isEmpty else { return }
        let prev = entries[workerID]
        let effectiveHostname = hostname.isEmpty ? (prev?.hostname ?? "") : hostname
        let effectiveVersion = runnerVersion.isEmpty ? (prev?.runnerVersion ?? "") : runnerVersion
        let effectiveConcurrency = maxConcurrentJobs == 0 ? (prev?.maxConcurrentJobs ?? 0) : maxConcurrentJobs
        let effectiveActiveJobs = max(0, activeJobs ?? (prev?.activeJobs ?? 0))
        entries[workerID] = Entry(
            lastSeen: date,
            hostname: effectiveHostname,
            runnerVersion: effectiveVersion,
            maxConcurrentJobs: effectiveConcurrency,
            activeJobs: effectiveActiveJobs,
            lastPollAt: lastPollAt ?? prev?.lastPollAt,
            lastHeartbeatAt: lastHeartbeatAt ?? prev?.lastHeartbeatAt,
            serverAssignedJobCountSinceStart: prev?.serverAssignedJobCountSinceStart ?? 0
        )
    }

    func incrementAssignedJobs(for workerID: String) {
        guard let entry = entries[workerID] else { return }
        entries[workerID] = Entry(
            lastSeen: entry.lastSeen,
            hostname: entry.hostname,
            runnerVersion: entry.runnerVersion,
            maxConcurrentJobs: entry.maxConcurrentJobs,
            activeJobs: entry.activeJobs,
            lastPollAt: entry.lastPollAt,
            lastHeartbeatAt: entry.lastHeartbeatAt,
            serverAssignedJobCountSinceStart: entry.serverAssignedJobCountSinceStart + 1
        )
    }

    func snapshot(for workerID: String) -> WorkerActivitySnapshot? {
        guard let entry = entries[workerID] else { return nil }
        return WorkerActivitySnapshot(
            workerID: workerID,
            lastActive: entry.lastSeen,
            hostname: entry.hostname,
            runnerVersion: entry.runnerVersion,
            maxConcurrentJobs: entry.maxConcurrentJobs,
            activeJobs: entry.activeJobs,
            lastPollAt: entry.lastPollAt,
            lastHeartbeatAt: entry.lastHeartbeatAt,
            serverAssignedJobCountSinceStart: entry.serverAssignedJobCountSinceStart
        )
    }

    /// Returns true when `workerID` has been seen within `ttlSeconds` AND the
    /// stored hostname differs from `hostname`. Same hostname = restart of the
    /// same runner process, which is not treated as a conflict.
    func isConflict(workerID: String, hostname: String, ttlSeconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let entry = entries[workerID] else { return false }
        let withinTTL = now.timeIntervalSince(entry.lastSeen) <= ttlSeconds
        return withinTTL && !entry.hostname.isEmpty && entry.hostname != hostname
    }

    /// Returns snapshots for runners seen within `cutoff` seconds, pruning
    /// stale entries from the in-memory store at the same time.  Runners that
    /// have not contacted the server for more than an hour are dropped so they
    /// don't accumulate forever after a rename or permanent shutdown.
    func snapshotsSortedByRecent(cutoff: TimeInterval = 3600, now: Date = Date()) -> [WorkerActivitySnapshot] {
        // Prune any entry that hasn't been seen within the cutoff window.
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= cutoff }
        return
            entries
            .map {
                WorkerActivitySnapshot(
                    workerID: $0.key,
                    lastActive: $0.value.lastSeen,
                    hostname: $0.value.hostname,
                    runnerVersion: $0.value.runnerVersion,
                    maxConcurrentJobs: $0.value.maxConcurrentJobs,
                    activeJobs: $0.value.activeJobs,
                    lastPollAt: $0.value.lastPollAt,
                    lastHeartbeatAt: $0.value.lastHeartbeatAt,
                    serverAssignedJobCountSinceStart: $0.value.serverAssignedJobCountSinceStart
                )
            }
            .sorted { $0.lastActive > $1.lastActive }
    }

    func hasRecentActivity(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        entries.values.contains { now.timeIntervalSince($0.lastSeen) <= seconds }
    }

    /// Non-mutating presence signal for proactive runner alerting.
    ///
    /// - `anyRecent`: at least one runner checked in within `graceSeconds`.
    /// - `anyKnown`: at least one runner checked in within `rememberSeconds`,
    ///   i.e. we still remember it existing this session.
    ///
    /// The pair lets the alert fire when a runner we've *seen* goes quiet past
    /// the grace period — even with an empty queue — while staying silent when
    /// no runner has ever connected (`anyKnown == false`). Unlike
    /// `snapshotsSortedByRecent`, this does not prune the store, so evaluating
    /// the alert never races the dashboard's pruning. `rememberSeconds` should
    /// match that prune cutoff so a long-dead runner is "forgotten" at the same
    /// point the dashboard drops it.
    func runnerPresence(
        graceSeconds: TimeInterval,
        rememberSeconds: TimeInterval,
        now: Date = Date()
    ) -> (anyRecent: Bool, anyKnown: Bool) {
        var anyRecent = false
        var anyKnown = false
        for entry in entries.values {
            let age = now.timeIntervalSince(entry.lastSeen)
            if age <= graceSeconds { anyRecent = true }
            if age <= rememberSeconds { anyKnown = true }
        }
        return (anyRecent, anyKnown)
    }
}

actor LocalRunnerAutoStartStore {
    private var enabled: Bool

    init(initialEnabled: Bool) {
        self.enabled = initialEnabled
    }

    func isEnabled() -> Bool {
        enabled
    }

    func setEnabled(_ newValue: Bool) {
        enabled = newValue
    }
}

actor LocalRunnerManager {
    private var process: Process?
    private var logHandle: FileHandle?

    func ensureRunning(app: Application, logger: Logger) async {
        if let existing = process, existing.isRunning {
            return
        }

        let secret = (await app.workerSecretStore.runtimeOverrideValue() ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !secret.isEmpty else {
            logger.warning("Local runner autostart is enabled, but worker secret is empty.")
            return
        }

        let workDir = DirectoryConfiguration.detect().workingDirectory
        let host = normalizedHost(app.http.server.configuration.hostname)
        let port = app.http.server.configuration.port
        let apiBaseURL = "http://\(host):\(port)"
        let workerID = "autospawn-\(UUID().uuidString.lowercased().prefix(8))"
        let runnerBinary = workDir + ".build/debug/chickadee-runner"
        let launchViaBinary = FileManager.default.isExecutableFile(atPath: runnerBinary)
        let argsPrefix = launchViaBinary ? [runnerBinary] : ["swift", "run", "chickadee-runner"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments =
            argsPrefix + [
                "--api-base-url", apiBaseURL,
                "--worker-id", workerID,
                "--max-jobs", "1",
                "--sandbox",
            ]
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment["RUNNER_SHARED_SECRET"] = secret
        // Keep legacy name for older runners until all environments migrate.
        childEnvironment["WORKER_SHARED_SECRET"] = secret
        proc.environment = childEnvironment
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let logPath = workDir + "results/local-runner.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            _ = try? handle.seekToEnd()
            proc.standardOutput = handle
            proc.standardError = handle
            logHandle = handle
        }

        do {
            try proc.run()
            process = proc
            logger.info("Started local runner \(workerID) (\(launchViaBinary ? "binary" : "swift run"))")
        } catch {
            logger.error("Failed to start local runner: \(error)")
            process = nil
            if let handle = logHandle {
                try? handle.close()
                logHandle = nil
            }
        }
    }

    func stopIfRunning(logger: Logger) async {
        guard let proc = process else {
            if let handle = logHandle {
                try? handle.close()
                logHandle = nil
            }
            return
        }

        if proc.isRunning {
            logger.info("Stopping local runner process...")
            proc.terminate()
            for _ in 0..<20 where proc.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if proc.isRunning {
                proc.interrupt()
                for _ in 0..<10 where proc.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        if let handle = logHandle {
            try? handle.close()
            logHandle = nil
        }
        process = nil
    }
}

func normalizedHost(_ raw: String) -> String {
    let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.isEmpty || host == "0.0.0.0" || host == "::" {
        return "localhost"
    }
    return host
}

/// Reads the runner ↔ server shared secret from the environment. Kept as a
/// free function (rather than inlining `app.appConfig.workers.sharedSecret`)
/// because `WorkerSecretStore` is an actor without an `Application` handle and
/// needs a fresh read after admin-panel clears so the env fallback still wins.
func runnerSharedSecretFromEnvironment() -> String? {
    trimmedEnv("RUNNER_SHARED_SECRET") ?? trimmedEnv("WORKER_SHARED_SECRET")
}

// `environmentBool` and `parseSSOIdentityAllowlist` live in
// `Configuration/EnvParsing.swift`.

func extractWorkerSecretArgument(from env: inout Environment) -> String? {
    let args = env.arguments
    guard !args.isEmpty else { return nil }

    var found: String?
    var cleaned: [String] = []
    cleaned.reserveCapacity(args.count)
    cleaned.append(args[0])  // executable path

    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--worker-secret" {
            if i + 1 < args.count {
                let value = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { found = value }
                i += 2
                continue
            }
            i += 1
            continue
        }
        if arg.hasPrefix("--worker-secret=") {
            let raw = String(arg.dropFirst("--worker-secret=".count))
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { found = value }
            i += 1
            continue
        }
        cleaned.append(arg)
        i += 1
    }

    env.arguments = cleaned
    return found
}

func resolveStartupWorkerSecret(
    cliWorkerSecret: String?,
    workerSecretFilePath: String,
    workerSecretWordlistPath: String
) -> String {
    // 1. Explicit CLI argument — highest priority.
    if let cli = cliWorkerSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
        !cli.isEmpty,
        !isPlaceholderWorkerSecret(cli)
    {
        writeWorkerSecretToDisk(secret: cli, workerSecretFilePath: workerSecretFilePath)
        return cli
    }
    // 2. RUNNER_SHARED_SECRET environment variable — how Docker Compose and systemd
    //    configure the secret.  Checked before the disk file so that setting the env
    //    var is always sufficient to sync the server and runner; the disk file is only
    //    used when no env var is present (development / auto-generated mode).
    if let envSecret = runnerSharedSecretFromEnvironment(),
        !isPlaceholderWorkerSecret(envSecret)
    {
        return envSecret
    }
    // 3. Previously persisted secret on disk (written by auto-generate or admin panel).
    if let previous = readWorkerSecretFromDisk(workerSecretFilePath: workerSecretFilePath),
        !previous.isEmpty,
        !isPlaceholderWorkerSecret(previous)
    {
        return previous
    }
    // 4. Auto-generate a diceware passphrase (dev / first-time startup with no env var).
    let generated = randomWorkerPassphrase(workerSecretWordlistPath: workerSecretWordlistPath)
    writeWorkerSecretToDisk(secret: generated, workerSecretFilePath: workerSecretFilePath)
    return generated
}

func readWorkerSecretFromDisk(workerSecretFilePath: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: workerSecretFilePath)),
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
    else {
        return nil
    }
    // Harden permissions on files written by older builds that ran before
    // writeWorkerSecretToDisk set the mode explicitly.
    restrictWorkerSecretFilePermissions(at: workerSecretFilePath)
    return text
}

func writeWorkerSecretToDisk(secret: String, workerSecretFilePath: String) {
    let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let url = URL(fileURLWithPath: workerSecretFilePath)
    try? value.write(to: url, atomically: true, encoding: .utf8)
    // The runner shared secret is the HMAC signing key for every worker
    // request.  Default umask (typically 0644 on Linux) lets any local user
    // read it and forge worker traffic; restrict to owner read/write only.
    restrictWorkerSecretFilePermissions(at: workerSecretFilePath)
}

private func restrictWorkerSecretFilePermissions(at path: String) {
    try? FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: path
    )
}

func randomWorkerPassphrase(workerSecretWordlistPath: String) -> String {
    let fallbackWords = [
        "oak", "river", "falcon", "amber", "lumen", "cedar", "thunder", "pebble",
        "meadow", "quartz", "north", "willow", "harbor", "maple", "breeze",
        "summit", "pixel", "cipher", "comet", "forest", "frost", "sparrow",
        "orbit", "cobalt", "dawn", "ember", "ridge", "tunnel", "canyon", "signal",
    ]
    let words = loadDicewareWords(from: workerSecretWordlistPath)
    let source = words.count >= 2048 ? words : fallbackWords
    return (0..<3).compactMap { _ in source.randomElement() }.joined(separator: "-")
}

func isPlaceholderWorkerSecret(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cli-arg-secret"
}

func loadDicewareWords(from path: String) -> [String] {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
    }

    var words: [String] = []
    words.reserveCapacity(8000)
    for line in raw.split(whereSeparator: \.isNewline) {
        let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { continue }
        let token = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { continue }
        words.append(token)
    }
    return words
}

func readLocalRunnerAutoStartFromDisk(filePath: String) -> Bool? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
        !text.isEmpty
    else {
        return nil
    }
    return text == "1" || text == "true" || text == "yes" || text == "on"
}

func writeLocalRunnerAutoStartToDisk(enabled: Bool, filePath: String) {
    let value = enabled ? "1" : "0"
    try? value.write(to: URL(fileURLWithPath: filePath), atomically: true, encoding: .utf8)
}
