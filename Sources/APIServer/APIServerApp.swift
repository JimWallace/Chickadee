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

        let app = Application(env)
        defer { app.shutdown() }

        try configure(app)
        try await app.run()
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

    // MARK: - Views + static files

    app.views.use(.leaf)
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // MARK: - Database

    app.databases.use(.sqlite(.file(workDir + "chickadee.sqlite")), as: .sqlite)

    app.migrations.add(CreateTestSetups())
    app.migrations.add(CreateSubmissions())
    app.migrations.add(CreateResults())
    app.migrations.add(AddAttemptNumberToSubmissions())

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
}
