// APIServer/Models/APIDataExport.swift
//
// Tracks a user's personal-data export (#557 — FIPPA / PIPEDA subject
// access).  Exactly one row per user (unique on user_id): a new request
// resets the existing row rather than accumulating history, so the table
// doubles as the "one export per day" rate-limit ledger and the download
// endpoint never has to disambiguate.  The audit log carries the durable
// history of who exported when.
//
// The generated zip lives on disk at `zipPath` (under
// `Application.dataExportsDirectory`) and is deleted by the retention
// reaper (`DataExportRetentionService`) once the row expires — exported
// personal data must not linger on the server indefinitely.

import Fluent
import Vapor

/// Lifecycle states for a data-export row.  The `status` DB column stays a
/// plain string; this enum is the authoritative vocabulary for it.
enum DataExportStatus: String, Sendable {
    /// Requested; generation is running (or was interrupted — see
    /// `dataExportStalePendingAge` for the self-heal window).
    case pending
    case complete
    case failed
}

final class APIDataExport: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context or the
    // single generation task that owns the row while it is pending.
    static let schema = "data_exports"

    @ID(key: .id)
    var id: UUID?

    /// The user this export belongs to.  Stored directly as UUID (not via
    /// @Parent) — same convention as `APICourseEnrollment.userID`.
    @Field(key: "user_id")
    var userID: UUID

    /// `DataExportStatus` raw value; column stays a string.
    @Field(key: "status")
    var status: String

    /// When the user requested this export.  A plain field (not a
    /// `@Timestamp(.create)`) because a re-request resets the same row.
    @Field(key: "requested_at")
    var requestedAt: Date

    @OptionalField(key: "completed_at")
    var completedAt: Date?

    /// Absolute path of the generated zip; nil until generation completes.
    @OptionalField(key: "zip_path")
    var zipPath: String?

    @OptionalField(key: "file_size_bytes")
    var fileSizeBytes: Int?

    /// Short operator-facing failure description.  Never rendered to the
    /// user (the UI only says the export failed).
    @OptionalField(key: "failure_reason")
    var failureReason: String?

    init() {}

    init(id: UUID? = nil, userID: UUID, requestedAt: Date = Date()) {
        self.id = id
        self.userID = userID
        self.status = DataExportStatus.pending.rawValue
        self.requestedAt = requestedAt
    }
}

// MARK: - Typed status accessors

extension APIDataExport {
    /// The export's status as a typed enum, or nil if the stored string is
    /// outside the known vocabulary (defensive — should not happen).
    var statusValue: DataExportStatus? { DataExportStatus(rawValue: status) }

    /// Sets the status from the typed enum.  Prefer this over assigning a
    /// raw string to `status`.
    func setStatus(_ newStatus: DataExportStatus) {
        status = newStatus.rawValue
    }
}
