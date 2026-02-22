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
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        
        do {
            try configure(app)
            try await app.execute()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        
        try await app.asyncShutdown()
    }
}

func configure(_ app: Application) throws {
    let workDir = DirectoryConfiguration.detect().workingDirectory

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
    app.storage[WorkerSecretStoreKey.self]    = WorkerSecretStore(initialOverride: randomWorkerPassphrase())
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

private func randomWorkerPassphrase() -> String {
    let words = [
        "oak", "river", "falcon", "amber", "lumen", "cedar", "thunder", "pebble",
        "meadow", "quartz", "north", "willow", "harbor", "maple", "breeze",
        "summit", "pixel", "cipher", "comet", "forest", "frost", "sparrow",
        "orbit", "cobalt", "dawn", "ember", "ridge", "tunnel", "canyon", "signal"
    ]
    return (0..<3).compactMap { _ in words.randomElement() }.joined(separator: "-")
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
}
