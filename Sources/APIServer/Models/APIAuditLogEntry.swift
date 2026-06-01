// APIServer/Models/APIAuditLogEntry.swift
//
// Structured audit log for admin-tier and security-sensitive actions.
// Server-only model: stored on disk, surfaced to the admin /admin/audit
// view, not part of any client-visible API.
//
// Fields:
//   actor_user_id    — UUID of the user who took the action (nil for
//                      anonymous events such as failed logins)
//   actor_username   — denormalised at write time so deleted users don't
//                      orphan their history
//   action           — short stable identifier (see `AuditAction`)
//   target_type      — coarse category of what the action was against
//                      ("user", "submission", "test_setup", "runner",
//                      "auth")
//   target_id        — opaque identifier for the target (e.g. UUID or
//                      submission slug); free-form because it varies by
//                      action
//   remote_addr      — client IP at action time
//   user_agent       — User-Agent header at action time
//   metadata         — JSON blob with action-specific context

import Fluent
import Vapor

final class APIAuditLogEntry: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "audit_log"

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "actor_user_id")
    var actorUserID: UUID?

    @OptionalField(key: "actor_username")
    var actorUsername: String?

    @Field(key: "action")
    var action: String

    @OptionalField(key: "target_type")
    var targetType: String?

    @OptionalField(key: "target_id")
    var targetID: String?

    @OptionalField(key: "remote_addr")
    var remoteAddr: String?

    @OptionalField(key: "user_agent")
    var userAgent: String?

    @OptionalField(key: "metadata")
    var metadata: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        actorUserID: UUID? = nil,
        actorUsername: String? = nil,
        action: String,
        targetType: String? = nil,
        targetID: String? = nil,
        remoteAddr: String? = nil,
        userAgent: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.actorUserID = actorUserID
        self.actorUsername = actorUsername
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.remoteAddr = remoteAddr
        self.userAgent = userAgent
        self.metadata = metadata
    }
}

/// Stable identifiers for audit-logged actions.  Kept as an enum so a typo
/// can't silently produce an orphaned action string in the table.
enum AuditAction: String, Sendable {
    case userDeleted = "user.deleted"
    case userRoleChanged = "user.role_changed"
    case runnerSecretRotated = "runner.secret_rotated"
    case runnerAutostartChanged = "runner.autostart_changed"
    case courseArchived = "course.archived"
    case courseUnarchived = "course.unarchived"
    case submissionsPurged = "submission.retention_purged"
    case submissionRetestAll = "submission.retest_all"
    case submissionRetestForStudent = "submission.retest_for_student"
    case extensionGranted = "extension.granted"
    case extensionRevoked = "extension.revoked"
    case loginSuccess = "auth.login_success"
    case loginFailure = "auth.login_failure"
    case loginLocked = "auth.login_locked"
    case sessionIdleTimeout = "auth.session_idle_timeout"
    case mcpAccountCreated = "mcp.account_created"
    case mcpAccountDeleted = "mcp.account_deleted"
    case mcpTokenMinted = "mcp.token_minted"
    case mcpToolCalled = "mcp.tool_called"
    case mcpGrantRevoked = "mcp.grant_revoked"
    case mcpAccountEnrolled = "mcp.account_enrolled"
    case mcpAccountUnenrolled = "mcp.account_unenrolled"
}

enum AuditTargetType: String, Sendable {
    case user
    case runner
    case testSetup = "test_setup"
    case auth
    case assignment
    case course
}
