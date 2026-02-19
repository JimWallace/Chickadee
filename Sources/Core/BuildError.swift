// Core/BuildError.swift
//
// Single typed error enum used throughout the build pipeline.
// Spec §3: "Replace with a single typed enum used throughout."

/// All failure modes the build pipeline can encounter.
enum BuildError: Error, LocalizedError {
    case missingConfiguration(key: String)
    case compileFailure(output: String)
    case internalError(String, underlying: Error? = nil)
    case networkFailure(underlying: Error)
    case alreadyRunning
    case shutdownRequested

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let key):
            return "Missing required configuration key: '\(key)'"
        case .compileFailure(let output):
            return "Compilation failed:\n\(output)"
        case .internalError(let msg, let underlying):
            if let u = underlying {
                return "Internal error: \(msg) (caused by: \(u))"
            }
            return "Internal error: \(msg)"
        case .networkFailure(let underlying):
            return "Network failure: \(underlying)"
        case .alreadyRunning:
            return "Another worker instance is already running (lock file held)"
        case .shutdownRequested:
            return "Shutdown requested"
        }
    }
}
