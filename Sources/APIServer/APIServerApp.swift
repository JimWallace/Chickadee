// APIServer/APIServerApp.swift

import Vapor
import Fluent
import FluentSQLiteDriver
import Leaf
import Foundation

@main
struct APIServerApp {
    static func main() async throws {
        var env = try Environment.detect()
        let cliWorkerSecret = extractWorkerSecretArgument(from: &env)
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        
        do {
            try configure(app, cliWorkerSecret: cliWorkerSecret)
            try await app.execute()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        
        try await app.asyncShutdown()
    }
}

func configure(_ app: Application, cliWorkerSecret: String?) throws {
    let workDir = DirectoryConfiguration.detect().workingDirectory
    let workerSecretFile = workDir + ".worker-secret"

    // MARK: - Directories

    let resultsDir    = workDir + "results/"
    let setupsDir     = workDir + "testsetups/"
    let submissionsDir = workDir + "submissions/"

    for dir in [resultsDir, setupsDir, submissionsDir] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    app.storage[ResultsDirectoryKey.self]     = resultsDir
    app.storage[TestSetupsDirectoryKey.self]  = setupsDir
    app.storage[SubmissionsDirectoryKey.self] = submissionsDir
    app.storage[WorkerSecretFilePathKey.self] = workerSecretFile
    let startupWorkerSecret = resolveStartupWorkerSecret(
        cliWorkerSecret: cliWorkerSecret,
        workerSecretFilePath: workerSecretFile
    )
    app.storage[WorkerSecretStoreKey.self]    = WorkerSecretStore(initialOverride: startupWorkerSecret)
    app.storage[WorkerActivityStoreKey.self]  = WorkerActivityStore()

    // MARK: - Sessions (in-memory; swap to .fluent for multi-process deployments)

    app.sessions.use(.memory)
    app.middleware.use(app.sessions.middleware)
    // Allow notebook uploads from the assignment-creation flow.
    app.routes.defaultMaxBodySize = "10mb"

    // MARK: - Views + static files

    app.views.use(.leaf)
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // MARK: - Database

    app.databases.use(.sqlite(.file(workDir + "chickadee.sqlite")), as: .sqlite)

    app.migrations.add(CreateTestSetups())
    app.migrations.add(CreateSubmissions())
    app.migrations.add(CreateResults())
    app.migrations.add(AddAttemptNumberToSubmissions())
    app.migrations.add(AddFilenameToSubmissions())
    app.migrations.add(AddSourceToResults())
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateAssignments())
    app.migrations.add(AddUserIDToSubmissions())
    app.migrations.add(AddNotebookPathToTestSetups())

    try app.autoMigrate().wait()

    // MARK: - Routes

    try routes(app)
}

// MARK: - Storage keys

struct ResultsDirectoryKey: StorageKey {
    typealias Value = String
}
struct TestSetupsDirectoryKey: StorageKey {
    typealias Value = String
}
struct SubmissionsDirectoryKey: StorageKey {
    typealias Value = String
}
struct WorkerSecretStoreKey: StorageKey {
    typealias Value = WorkerSecretStore
}
struct WorkerSecretFilePathKey: StorageKey {
    typealias Value = String
}
struct WorkerActivityStoreKey: StorageKey {
    typealias Value = WorkerActivityStore
}

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
        runtimeOverride ?? Environment.get("WORKER_SHARED_SECRET")
    }
}

struct WorkerActivitySnapshot: Sendable {
    let workerID: String
    let lastActive: Date
}

actor WorkerActivityStore {
    private var lastSeenByWorkerID: [String: Date] = [:]

    func markActive(workerID: String, at date: Date = Date()) {
        guard !workerID.isEmpty else { return }
        lastSeenByWorkerID[workerID] = date
    }

    func snapshotsSortedByRecent() -> [WorkerActivitySnapshot] {
        lastSeenByWorkerID
            .map { WorkerActivitySnapshot(workerID: $0.key, lastActive: $0.value) }
            .sorted { $0.lastActive > $1.lastActive }
    }
}

extension Application {
    var resultsDirectory: String {
        get { storage[ResultsDirectoryKey.self] ?? "results/" }
        set { storage[ResultsDirectoryKey.self] = newValue }
    }
    var testSetupsDirectory: String {
        get { storage[TestSetupsDirectoryKey.self] ?? "testsetups/" }
        set { storage[TestSetupsDirectoryKey.self] = newValue }
    }
    var submissionsDirectory: String {
        get { storage[SubmissionsDirectoryKey.self] ?? "submissions/" }
        set { storage[SubmissionsDirectoryKey.self] = newValue }
    }

    var workerSecretStore: WorkerSecretStore {
        get {
            if let existing = storage[WorkerSecretStoreKey.self] {
                return existing
            }
            let created = WorkerSecretStore()
            storage[WorkerSecretStoreKey.self] = created
            return created
        }
        set {
            storage[WorkerSecretStoreKey.self] = newValue
        }
    }

    var workerActivityStore: WorkerActivityStore {
        get {
            if let existing = storage[WorkerActivityStoreKey.self] {
                return existing
            }
            let created = WorkerActivityStore()
            storage[WorkerActivityStoreKey.self] = created
            return created
        }
        set {
            storage[WorkerActivityStoreKey.self] = newValue
        }
    }

    var workerSecretFilePath: String {
        get { storage[WorkerSecretFilePathKey.self] ?? (DirectoryConfiguration.detect().workingDirectory + ".worker-secret") }
        set { storage[WorkerSecretFilePathKey.self] = newValue }
    }
}

private func extractWorkerSecretArgument(from env: inout Environment) -> String? {
    let args = env.arguments
    guard !args.isEmpty else { return nil }

    var found: String?
    var cleaned: [String] = []
    cleaned.reserveCapacity(args.count)
    cleaned.append(args[0]) // executable path

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

private func resolveStartupWorkerSecret(cliWorkerSecret: String?, workerSecretFilePath: String) -> String {
    if let cli = cliWorkerSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !cli.isEmpty {
        writeWorkerSecretToDisk(secret: cli, workerSecretFilePath: workerSecretFilePath)
        return cli
    }
    if let previous = readWorkerSecretFromDisk(workerSecretFilePath: workerSecretFilePath), !previous.isEmpty {
        return previous
    }
    let generated = randomWorkerPassphrase()
    writeWorkerSecretToDisk(secret: generated, workerSecretFilePath: workerSecretFilePath)
    return generated
}

func readWorkerSecretFromDisk(workerSecretFilePath: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: workerSecretFilePath)),
          let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }
    return text
}

func writeWorkerSecretToDisk(secret: String, workerSecretFilePath: String) {
    let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let url = URL(fileURLWithPath: workerSecretFilePath)
    try? value.write(to: url, atomically: true, encoding: .utf8)
}

private func randomWorkerPassphrase() -> String {
    let words = [
        "oak", "river", "falcon", "amber", "lumen", "cedar", "thunder", "pebble",
        "meadow", "quartz", "north", "willow", "harbor", "maple", "breeze",
        "summit", "pixel", "cipher", "comet", "forest", "frost", "sparrow",
        "orbit", "cobalt", "dawn", "ember", "ridge", "tunnel", "canyon", "signal"
    ]
    return (0..<3).compactMap { _ in words.randomElement() }.joined(separator: "-")
}
