// APIServer/MCP/Tools/ValidationWatch.swift
//
// Shared logic for watching an assignment's runner validation to a terminal
// state, used by both the (non-streaming) validate_assignment tool and the
// SSE progress-streaming path in MCPRoutes. Pure `Database` access — no Vapor
// `Request` — so it is safe to run from a request handler (`request.db`) or
// from a `@Sendable` streamed-response closure (`application.db`).

import Core
import Fluent
import Foundation

/// Coarse phase of a validation run, derived from the assignment's
/// `validationStatus` plus its validation submission's row status. Raw values
/// are ordered so a caller can detect forward progress.
enum ValidationPhase: Int, Sendable, Comparable {
    case queued = 0  // enqueued, submission still pending
    case running = 1  // submission claimed by a worker (assigned/running)
    case done = 2  // assignment reached a terminal validationStatus

    static func < (lhs: ValidationPhase, rhs: ValidationPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Fraction toward completion surfaced in `notifications/progress`.
    var progressFraction: Double {
        switch self {
        case .queued: return 0.25
        case .running: return 0.66
        case .done: return 1.0
        }
    }
}

/// Terminal outcome of a validation watch.
struct ValidationWatchOutcome: Sendable {
    let assignmentPublicID: String
    /// "passed" | "failed" | "no-runner" | "pending" | "none" — the assignment's
    /// `validationStatus` at the point the watch stopped (terminal or timeout).
    let validationStatus: String
    /// True when the watch hit its deadline before validation reached a terminal
    /// state (still pending/running).
    let timedOut: Bool
}

/// The terminal `validationStatus` values that stop the watch.
private let terminalValidationStatuses: Set<String> = ["passed", "failed", "no-runner"]

/// Polls the assignment (and its validation submission) until validation reaches
/// a terminal state or `deadline` passes, invoking `emit` once per forward phase
/// change. `emit` receives the progress fraction and a short human message.
@discardableResult
func watchValidation(
    on db: Database,
    assignmentPublicID: String,
    pollInterval: Duration,
    deadline: ContinuousClock.Instant,
    clock: ContinuousClock = ContinuousClock(),
    emit: (Double, String) async -> Void
) async throws -> ValidationWatchOutcome {
    var lastPhase: ValidationPhase?

    while true {
        let (status, phase) = try await currentValidationPhase(
            on: db, assignmentPublicID: assignmentPublicID)

        if lastPhase == nil || phase > (lastPhase ?? .queued) {
            lastPhase = phase
            await emit(phase.progressFraction, message(for: phase, status: status))
        }

        if phase == .done {
            return ValidationWatchOutcome(
                assignmentPublicID: assignmentPublicID,
                validationStatus: status ?? "none", timedOut: false)
        }
        if clock.now >= deadline {
            return ValidationWatchOutcome(
                assignmentPublicID: assignmentPublicID,
                validationStatus: status ?? "pending", timedOut: true)
        }
        try await Task.sleep(for: pollInterval)
    }
}

/// Reads the assignment's current validation status + derived phase. A missing
/// assignment is treated as still-queued (the caller authorized it before the
/// watch began, so this only happens on a transient read).
private func currentValidationPhase(
    on db: Database, assignmentPublicID: String
) async throws -> (status: String?, phase: ValidationPhase) {
    guard let assignment = try await assignmentByPublicID(assignmentPublicID, on: db) else {
        return (nil, .queued)
    }
    let status = assignment.validationStatus
    if let status, terminalValidationStatuses.contains(status) {
        return (status, .done)
    }
    // Not terminal: distinguish "queued" from "running" via the submission row.
    if let subID = assignment.validationSubmissionID,
        let submission = try await APISubmission.find(subID, on: db)
    {
        switch submission.status {
        case "assigned", "running": return (status, .running)
        default: return (status, .queued)
        }
    }
    return (status, .queued)
}

private func message(for phase: ValidationPhase, status: String?) -> String {
    switch phase {
    case .queued: return "Queued for validation"
    case .running: return "Running on a worker"
    case .done: return "Validation \(status ?? "complete")"
    }
}
