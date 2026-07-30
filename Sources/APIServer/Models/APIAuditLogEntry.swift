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

    /// The course this event belongs to, when it has one.
    ///
    /// Course scoping used to live only inside the `metadata` JSON, which is
    /// unindexable and silently absent wherever a call site forgot the key.
    /// This is the indexed, first-class form the per-course activity view
    /// (#421) filters on; `CreateAuditLog` backfills it from the existing
    /// metadata. Nil for deployment-wide events (logins, runner secret
    /// rotation, user deletion).
    @OptionalField(key: "course_id")
    var courseID: UUID?

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
        metadata: String? = nil,
        courseID: UUID? = nil
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
        self.courseID = courseID
    }
}

/// Stable identifiers for audit-logged actions.  Kept as an enum so a typo
/// can't silently produce an orphaned action string in the table.
///
/// `CaseIterable` drives the action-filter dropdown on /admin/audit and the
/// coverage test that asserts every action has a human-readable display
/// mapping (`AuditActionDisplayTests`).
enum AuditAction: String, Sendable, CaseIterable {
    // Authentication & session
    case loginSuccess = "auth.login_success"
    case loginFailure = "auth.login_failure"
    case loginLocked = "auth.login_locked"
    case logout = "auth.logout"
    case sessionIdleTimeout = "auth.session_idle_timeout"

    // Users & roles
    case userRegistered = "user.registered"
    case userProvisioned = "user.provisioned"
    case userRoleChanged = "user.role_changed"
    case userDeleted = "user.deleted"
    case userDataExportRequested = "user.data_export_requested"
    case userDataExportDownloaded = "user.data_export_downloaded"

    // Courses
    case courseCreated = "course.created"
    case courseArchived = "course.archived"
    case courseUnarchived = "course.unarchived"
    case courseDeleted = "course.deleted"
    case courseBundleImported = "course.bundle_imported"
    case courseBundleExported = "course.bundle_exported"

    // Enrollment
    case enrollmentBulkAdded = "enrollment.bulk_added"
    case enrollmentRemoved = "enrollment.removed"
    case enrollmentRoleChanged = "enrollment.role_changed"

    // Assignment lifecycle (#421). Content edits are recorded separately and in
    // far more detail by `assignment_versions`; these are the metadata and
    // existence changes versioning deliberately does NOT cover — a restore
    // never touches them, and a deleted assignment leaves no version row to
    // read.
    case assignmentCreated = "assignment.created"
    case assignmentCloned = "assignment.cloned"
    case assignmentDeleted = "assignment.deleted"
    case assignmentVisibilityChanged = "assignment.visibility_changed"
    case assignmentDueDateChanged = "assignment.due_date_changed"

    // Submissions
    case submissionsPurged = "submission.retention_purged"
    case submissionRetestAll = "submission.retest_all"
    case submissionRetestForStudent = "submission.retest_for_student"

    // Grading overrides & extensions
    case extensionGranted = "extension.granted"
    case extensionRevoked = "extension.revoked"
    case gradeOverrideSet = "grade_override.set"
    case gradeOverrideCleared = "grade_override.cleared"

    // Secret reveal tokens
    case secretRevealSpent = "secret_reveal.spent"
    case secretRevealRegranted = "secret_reveal.regranted"
    case secretRevealToggled = "secret_reveal.toggle_changed"

    // Slip days (#1228)
    case slipDaySpent = "slip_day.spent"
    case slipDayRefunded = "slip_day.refunded"
    case slipDaySettingsChanged = "slip_day.settings_changed"
    case slipDayAdjustmentChanged = "slip_day.adjustment_changed"

    // Runner / worker
    case runnerSecretRotated = "runner.secret_rotated"
    case runnerAutostartChanged = "runner.autostart_changed"

    // BrightSpace / LEARN grade sync (actor-driven actions only — individual
    // grade pushes are background events recorded in `brightspace_sync_log`)
    case brightspaceAdminAuthorized = "brightspace.admin_authorized"
    case brightspaceAdminCleared = "brightspace.admin_cleared"
    case brightspaceAccountConnected = "brightspace.account_connected"
    case brightspaceAccountDisconnected = "brightspace.account_disconnected"
    case brightspaceSyncIdentitySet = "brightspace.sync_identity_set"
    case brightspaceOrgUnitBound = "brightspace.org_unit_bound"
    case brightspaceOrgUnitCleared = "brightspace.org_unit_cleared"
    case brightspaceGradeItemMapped = "brightspace.grade_item_mapped"
    case brightspaceAutoMapped = "brightspace.auto_mapped"
    case brightspaceSyncNow = "brightspace.sync_now"
    case brightspacePushAll = "brightspace.push_all"

    // MCP / agents
    case mcpAccountCreated = "mcp.account_created"
    case mcpAccountDeleted = "mcp.account_deleted"
    case mcpTokenMinted = "mcp.token_minted"
    case mcpToolCalled = "mcp.tool_called"
    case mcpGrantRevoked = "mcp.grant_revoked"
    case mcpAccountEnrolled = "mcp.account_enrolled"
    case mcpAccountUnenrolled = "mcp.account_unenrolled"
    case mcpClientRegistered = "mcp.client_registered"
    case mcpConsentGranted = "mcp.consent_granted"
    case mcpTokenIssued = "mcp.token_issued"
    case mcpRefreshReuseDetected = "mcp.refresh_reuse_detected"
    case mcpCourseInstructionsUpdated = "mcp.course_instructions_updated"
    case adminMcpToolCalled = "admin_mcp.tool_called"

    /// Coarse grouping shown as the "Category" column / filter on /admin/audit.
    var category: AuditCategory {
        switch self {
        case .loginSuccess, .loginFailure, .loginLocked, .logout, .sessionIdleTimeout:
            return .authentication
        case .userRegistered, .userProvisioned, .userRoleChanged, .userDeleted,
            .userDataExportRequested, .userDataExportDownloaded:
            return .users
        case .courseCreated, .courseArchived, .courseUnarchived, .courseDeleted,
            .courseBundleImported, .courseBundleExported:
            return .courses
        case .enrollmentBulkAdded, .enrollmentRemoved, .enrollmentRoleChanged:
            return .enrollment
        case .assignmentCreated, .assignmentCloned, .assignmentDeleted,
            .assignmentVisibilityChanged, .assignmentDueDateChanged:
            return .assignments
        case .submissionsPurged, .submissionRetestAll, .submissionRetestForStudent:
            return .submissions
        case .extensionGranted, .extensionRevoked, .gradeOverrideSet, .gradeOverrideCleared,
            .secretRevealSpent, .secretRevealRegranted, .secretRevealToggled,
            .slipDaySpent, .slipDayRefunded, .slipDayAdjustmentChanged:
            return .grading
        // Course-wide slip-day policy is course configuration, not a grading
        // action on one student.
        case .slipDaySettingsChanged:
            return .courses
        case .runnerSecretRotated, .runnerAutostartChanged:
            return .runner
        case .brightspaceAdminAuthorized, .brightspaceAdminCleared, .brightspaceAccountConnected,
            .brightspaceAccountDisconnected, .brightspaceSyncIdentitySet, .brightspaceOrgUnitBound,
            .brightspaceOrgUnitCleared, .brightspaceGradeItemMapped, .brightspaceAutoMapped,
            .brightspaceSyncNow, .brightspacePushAll:
            return .brightspace
        case .mcpAccountCreated, .mcpAccountDeleted, .mcpTokenMinted, .mcpToolCalled,
            .mcpGrantRevoked, .mcpAccountEnrolled, .mcpAccountUnenrolled, .mcpClientRegistered,
            .mcpConsentGranted, .mcpTokenIssued, .mcpRefreshReuseDetected,
            .mcpCourseInstructionsUpdated, .adminMcpToolCalled:
            return .mcp
        }
    }

    /// Human-readable label shown in the admin table instead of the raw
    /// machine identifier (e.g. "MCP access authorized" for
    /// `mcp.consent_granted`).
    var label: String {
        switch self {
        case .loginSuccess: return "Login"
        case .loginFailure: return "Login failed"
        case .loginLocked: return "Login locked out"
        case .logout: return "Logout"
        case .sessionIdleTimeout: return "Session idle timeout"
        case .userRegistered: return "Account self-registered"
        case .userProvisioned: return "Account provisioned (SSO)"
        case .userRoleChanged: return "Role changed"
        case .userDeleted: return "User deleted"
        case .userDataExportRequested: return "Data export requested"
        case .userDataExportDownloaded: return "Data export downloaded"
        case .courseCreated: return "Course created"
        case .courseArchived: return "Course archived"
        case .courseUnarchived: return "Course unarchived"
        case .courseDeleted: return "Course deleted"
        case .courseBundleImported: return "Course bundle imported"
        case .courseBundleExported: return "Course bundle exported"
        case .enrollmentBulkAdded: return "Bulk enrollment"
        case .enrollmentRemoved: return "Unenrolled"
        case .enrollmentRoleChanged: return "Per-course role changed"
        case .assignmentCreated: return "Assignment created"
        case .assignmentCloned: return "Assignment cloned"
        case .assignmentDeleted: return "Assignment deleted"
        case .assignmentVisibilityChanged: return "Assignment visibility changed"
        case .assignmentDueDateChanged: return "Assignment due date changed"
        case .submissionsPurged: return "Submissions purged"
        case .submissionRetestAll: return "Retest all submissions"
        case .submissionRetestForStudent: return "Retest student submissions"
        case .extensionGranted: return "Extension granted"
        case .extensionRevoked: return "Extension revoked"
        case .gradeOverrideSet: return "Grade override set"
        case .gradeOverrideCleared: return "Grade override cleared"
        case .secretRevealSpent: return "Reveal token spent"
        case .secretRevealRegranted: return "Reveal token re-granted"
        case .secretRevealToggled: return "Reveal token setting changed"
        case .slipDaySpent: return "Slip day spent"
        case .slipDayRefunded: return "Slip day refunded"
        case .slipDaySettingsChanged: return "Slip day settings changed"
        case .slipDayAdjustmentChanged: return "Slip day budget adjusted"
        case .runnerSecretRotated: return "Runner secret rotated"
        case .runnerAutostartChanged: return "Runner autostart changed"
        case .brightspaceAdminAuthorized: return "LEARN deployment key authorized"
        case .brightspaceAdminCleared: return "LEARN deployment key cleared"
        case .brightspaceAccountConnected: return "LEARN account connected"
        case .brightspaceAccountDisconnected: return "LEARN account disconnected"
        case .brightspaceSyncIdentitySet: return "LEARN sync identity set"
        case .brightspaceOrgUnitBound: return "LEARN org unit linked"
        case .brightspaceOrgUnitCleared: return "LEARN org unit unlinked"
        case .brightspaceGradeItemMapped: return "LEARN grade item mapping changed"
        case .brightspaceAutoMapped: return "LEARN grade items auto-mapped"
        case .brightspaceSyncNow: return "LEARN manual sync"
        case .brightspacePushAll: return "LEARN push all grades"
        case .mcpAccountCreated: return "MCP account created"
        case .mcpAccountDeleted: return "MCP account deleted"
        case .mcpTokenMinted: return "MCP token minted (admin)"
        case .mcpToolCalled: return "MCP tool called"
        case .mcpGrantRevoked: return "MCP grant revoked"
        case .mcpAccountEnrolled: return "MCP account enrolled"
        case .mcpAccountUnenrolled: return "MCP account unenrolled"
        case .mcpClientRegistered: return "MCP client registered"
        case .mcpConsentGranted: return "MCP access authorized"
        case .mcpTokenIssued: return "MCP token issued"
        case .mcpRefreshReuseDetected: return "MCP refresh-token reuse detected"
        case .mcpCourseInstructionsUpdated: return "MCP course guidance updated"
        case .adminMcpToolCalled: return "Admin diagnostic tool called"
        }
    }
}

/// Coarse grouping for audit actions, surfaced as the "Category" column and the
/// category filter on /admin/audit.
enum AuditCategory: String, Sendable, CaseIterable {
    case authentication = "Authentication"
    case users = "Users & roles"
    case courses = "Courses"
    case enrollment = "Enrollment"
    case assignments = "Assignments"
    case submissions = "Submissions"
    case grading = "Grading"
    case runner = "Runner"
    case mcp = "MCP / agents"
    case brightspace = "LEARN sync"
}

/// Resolves a stored (raw) action string to its display category + label,
/// falling back gracefully for any historical action no longer in `AuditAction`
/// (e.g. written by an older server, then renamed).
enum AuditActionDisplay {
    static func categoryLabel(forRaw raw: String) -> (category: String, label: String) {
        if let action = AuditAction(rawValue: raw) {
            return (action.category.rawValue, action.label)
        }
        return ("Other", raw)
    }
}

enum AuditTargetType: String, Sendable {
    case user
    case runner
    case testSetup = "test_setup"
    case auth
    case assignment
    case course
    case enrollment
    case oauthClient = "oauth_client"
}
