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

    let resultsDir = workDir + "results/"
    let setupsDir = workDir + "testsetups/"
    let submissionsDir = workDir + "submissions/"

    for dir in [resultsDir, setupsDir, submissionsDir] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    app.storage[ResultsDirectoryKey.self] = resultsDir
    app.storage[TestSetupsDirectoryKey.self] = setupsDir
    app.storage[SubmissionsDirectoryKey.self] = submissionsDir
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
    app.storage[LocalRunnerAutoStartStoreKey.self] = LocalRunnerAutoStartStore(
        initialEnabled: localRunnerAutoStartEnabled
    )
    app.storage[LocalRunnerManagerKey.self] = LocalRunnerManager()
    app.authProvider = LocalAuthProvider()
}
