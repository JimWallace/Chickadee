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
    /// The request body is syntactically valid but its semantic content
    /// cannot be processed (e.g. a JSON payload that fails to decode into
    /// the expected `WorkerExecutionReport` schema). Maps to HTTP 422.
    case unprocessableBody(reason: String)
    /// A required resource was absent or in an unexpected state.
    case internalInconsistency(reason: String)

    var status: HTTPResponseStatus {
        switch self {
        case .testSetupNotFound:        return .notFound
        case .invalidBody:              return .badRequest
        case .unprocessableBody:        return .unprocessableEntity
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
        case .unprocessableBody(let reason):
            return "Unprocessable request body: \(reason)"
        case .internalInconsistency(let reason):
            return "Internal error: \(reason)"
        }
    }
}

// MARK: - Web instructor assignment routes

/// Errors raised by the instructor-facing assignment management web routes
/// (`AssignmentRoutes` and its `+Draft`, `+Editor`, `+Sections`, `+Submissions`
/// extensions).  Adopted incrementally — handlers migrate from `Abort(...)`
/// to these cases as the surrounding code is touched for other reasons.
enum WebAssignmentError: AbortError, CustomStringConvertible {
    /// A required entity (assignment, test setup, section, submission, …)
    /// could not be found.  The `resource` label is plain English so the
    /// rendered 404 reads naturally.
    case notFound(resource: String)
    /// Bad request — invalid body, missing parameter, malformed value.
    case invalidParameter(name: String, reason: String)
    /// The session has no active course but the action requires one.
    case noActiveCourse(action: String)
    /// The current user lacks the role required for this action.
    case forbidden(action: String)
    /// The request is well-formed but conflicts with current server state
    /// (e.g. duplicate filename, attempt to delete a setup that still has
    /// an associated assignment).
    case conflict(reason: String)
    /// The request was syntactically valid but its semantic content can't
    /// be processed (e.g. an invalid Python identifier, a duplicate name
    /// in a list that requires uniqueness).  Maps to HTTP 422.
    case unprocessable(reason: String)
    /// An assignment-validation precondition was not satisfied (e.g. the
    /// runner has not produced a passing validation result yet).
    case validationRequired(reason: String)
    /// A server-side write or external operation failed unexpectedly.
    case internalFailure(reason: String)

    var status: HTTPResponseStatus {
        switch self {
        case .notFound:             return .notFound
        case .invalidParameter:     return .badRequest
        case .noActiveCourse:       return .badRequest
        case .forbidden:            return .forbidden
        case .conflict:             return .conflict
        case .unprocessable:        return .unprocessableEntity
        case .validationRequired:   return .badRequest
        case .internalFailure:      return .internalServerError
        }
    }

    var reason: String { description }

    var description: String {
        switch self {
        case .notFound(let resource):
            return "\(resource) not found"
        case .invalidParameter(let name, let reason):
            return "Invalid \(name): \(reason)"
        case .noActiveCourse(let action):
            return "No active course selected. Please select a course before \(action)."
        case .forbidden(let action):
            return "You do not have permission to \(action)."
        case .conflict(let reason):
            return reason
        case .unprocessable(let reason):
            return reason
        case .validationRequired(let reason):
            return reason
        case .internalFailure(let reason):
            return reason
        }
    }
}
