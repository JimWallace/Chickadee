// APIServer/Errors/APIErrors.swift
//
// Domain-specific error types for the Chickadee API server.
//
// Each type conforms to Vapor's AbortError so the error middleware maps it
// to the correct HTTP status code automatically — no extra middleware shim
// required. Route handlers that use these types can declare typed throws,
// giving callers (and the compiler) a static enumeration of failure modes.
//
// Adoption strategy: new code should use these types; existing handlers
// migrate incrementally as they are touched for other reasons.

import Vapor

// MARK: - Notebook lookup

/// Errors that can occur when loading a notebook file for a test setup.
/// Thrown by `notebookData(for:)` and propagated through notebook page handlers.
enum NotebookLookupError: AbortError, CustomStringConvertible {
    /// The test setup has no associated notebook file (no flat .ipynb and
    /// no .ipynb entry inside the test-setup zip).
    case notFound(setupID: String)

    var status: HTTPResponseStatus {
        switch self {
        case .notFound: return .notFound
        }
    }

    var reason: String { description }

    var description: String {
        switch self {
        case .notFound(let id):
            return "No assignment notebook found for test setup \(id)"
        }
    }
}

// MARK: - Worker job endpoints

/// Errors that can occur in the worker job request / result submission flow.
/// Thrown by `WorkerJobRoutes` handlers.
enum WorkerJobError: AbortError, CustomStringConvertible {
    /// The referenced test setup does not exist in the database.
    case testSetupNotFound(id: String)
    /// The request body could not be decoded as the expected type.
    case invalidBody(reason: String)
    /// A required resource was absent or in an unexpected state.
    case internalInconsistency(reason: String)

    var status: HTTPResponseStatus {
        switch self {
        case .testSetupNotFound:        return .notFound
        case .invalidBody:              return .badRequest
        case .internalInconsistency:    return .internalServerError
        }
    }

    var reason: String { description }

    var description: String {
        switch self {
        case .testSetupNotFound(let id):
            return "Test setup \(id) not found"
        case .invalidBody(let reason):
            return "Invalid request body: \(reason)"
        case .internalInconsistency(let reason):
            return "Internal error: \(reason)"
        }
    }
}
