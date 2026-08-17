// APIServer/Bootstrap/AppDirectories.swift
//
// Creates the on-disk directories the server reads/writes (results,
// test setups, submissions) and seeds the Application storage with
// their paths plus the auxiliary service stores that depend on them
// (worker secret, local-runner autostart, worker activity tracker,
// claim queue).
//
// Extracted from configure(_:) in #496.

import Core
import Vapor

func bootstrapAppDirectories(_ app: Application, workDir: String, cliWorkerSecret: String?) throws {
    let workerSecretFile = workDir + ".worker-secret"
    let workerSecretWordlistFile = workDir + "Resources/wordlists/eff_large_wordlist.txt"
    let localRunnerAutoStartFile = workDir + ".local-runner-autostart"
    let alertWebhookURLFile = workDir + ".alert-webhook-url"
    let mcpClientAllowlistFile = workDir + ".mcp-client-allowlist"

    let resultsDir = workDir + "results/"
    let setupsDir = workDir + "testsetups/"
    let submissionsDir = workDir + "submissions/"
    let dataExportsDir = workDir + "data-exports/"
    let contentFilesDir = workDir + "content-files/"

    for dir in [resultsDir, setupsDir, submissionsDir, dataExportsDir, contentFilesDir] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    app.storage[ResultsDirectoryKey.self] = resultsDir
    app.storage[TestSetupsDirectoryKey.self] = setupsDir
    app.storage[SubmissionsDirectoryKey.self] = submissionsDir
    app.storage[DataExportsDirectoryKey.self] = dataExportsDir
    app.storage[ContentFilesDirectoryKey.self] = contentFilesDir
    // Read-only mount of the auto-deploy daemon's IPC dir (status.json /
    // history.jsonl); absolute host path, not under the data volume.  Read
    // through AppConfig like every other env var (#1129) so it shows up in
    // the redacted startup summary.
    app.storage[DeployStateDirectoryKey.self] = app.appConfig.diagnostics.deployStateDirectory
    app.storage[WorkerSecretFilePathKey.self] = workerSecretFile
    app.storage[LocalRunnerAutoStartFilePathKey.self] = localRunnerAutoStartFile
    app.storage[ServerHealthAlertWebhookURLFilePathKey.self] = alertWebhookURLFile

    let startupWorkerSecret = resolveStartupWorkerSecret(
        cliWorkerSecret: cliWorkerSecret,
        workerSecretFilePath: workerSecretFile,
        workerSecretWordlistPath: workerSecretWordlistFile
    )
    let localRunnerAutoStartEnabled =
        readLocalRunnerAutoStartFromDisk(filePath: localRunnerAutoStartFile) ?? false

    app.storage[WorkerClaimQueueKey.self] = WorkerClaimQueue()
    app.storage[WorkerSecretStoreKey.self] = WorkerSecretStore(initialOverride: startupWorkerSecret)
    app.storage[WorkerActivityStoreKey.self] = WorkerActivityStore()
    // Seeded eagerly (like the stores above) so request handlers never hit
    // the lazy-create branch in the accessor — Application.storage writes
    // are not synchronized.
    app.storage[ZipEntryListCacheKey.self] = ZipEntryListCache()
    app.storage[LocalRunnerAutoStartStoreKey.self] = LocalRunnerAutoStartStore(
        initialEnabled: localRunnerAutoStartEnabled
    )
    app.storage[LocalRunnerManagerKey.self] = LocalRunnerManager()
    app.storage[DataExportManagerKey.self] = DataExportManager()

    // Which OAuth clients an instructor may consent to, stated by the operator
    // in a file rather than an environment variable (standing repo rule).  Read
    // once here: the route-registration guards need it synchronously, and the
    // actor serves the per-request checks.
    app.storage[MCPClientAllowlistFilePathKey.self] = mcpClientAllowlistFile
    let clientAllowlist = readMCPClientAllowlistFromDisk(filePath: mcpClientAllowlistFile)
    app.storage[MCPClientAllowlistOriginsKey.self] = clientAllowlist.origins
    app.storage[MCPClientAllowlistStoreKey.self] = MCPClientAllowlistStore(
        initialOrigins: clientAllowlist.origins)
    if app.appConfig.mcp.mode.isMounted {
        for entry in clientAllowlist.invalidEntries {
            // Named rather than silently dropped: a typo here fails closed, and
            // an operator staring at a refused client needs to see why.
            let detail =
                "mcp: ignoring unusable client allowlist entry \"\(entry)\" — expected an origin "
                + "such as https://example.org (https required except for localhost)."
            app.logger.warning("\(detail)")
        }
        app.logger.info(
            "mcp: clientAllowlist=\(clientAllowlist.origins.count) origin(s) from \(mcpClientAllowlistFile)"
        )
    }

    app.authProvider = LocalAuthProvider()
}
