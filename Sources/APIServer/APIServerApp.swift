// APIServer/APIServerApp.swift

import Vapor
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
    // Store results in a directory relative to the working directory.
    // Phase 1: disk-only storage. No database dependency.
    let resultsDir = DirectoryConfiguration.detect().workingDirectory + "results/"
    try FileManager.default.createDirectory(
        atPath: resultsDir,
        withIntermediateDirectories: true
    )
    app.storage[ResultsDirectoryKey.self] = resultsDir

    try routes(app)
}

// MARK: - Storage key

struct ResultsDirectoryKey: StorageKey {
    typealias Value = String
}

extension Application {
    var resultsDirectory: String {
        get { storage[ResultsDirectoryKey.self] ?? "results/" }
        set { storage[ResultsDirectoryKey.self] = newValue }
    }
}
