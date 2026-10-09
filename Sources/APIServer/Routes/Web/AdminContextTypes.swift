// APIServer/Routes/Web/AdminContextTypes.swift
//
// Leaf template context types for the admin dashboard and its sub-pages.
// Separated from AdminRoutes.swift to keep route handlers readable.

import Core
import Vapor

struct AdminUserRow: Content {
    let id: String
    let displayName: String?
    let username: String
    let role: String
    let createdAt: String
    let lastSeenAt: String?
    /// The user's own seeded avatar, at the roster size; nil on the JSON feed's
    /// decode path for rows that predate it. `hasAvatar` is the flat flag the
    /// template branches on (a bare optional in a Leaf conditional is unreliable).
    var avatar: AvatarPresentation?
    var hasAvatar: Bool = false
    /// True for the row of the admin viewing the list. Its role menu is
    /// disabled, because an admin cannot change their own role.
    var isCurrentUser: Bool = false
}

/// One runner as the Overview table draws it: the facts of `AdminWorkerRow`
/// plus the strings and pips the row shows, built once so the page and the poll
/// fragment cannot disagree. The JSON feed keeps `AdminWorkerRow`.
struct AdminRunnerRow: Encodable {
    let workerID: String
    let isOffline: Bool
    let assignedJobs: Int
    let maxConcurrentJobs: Int
    let lastActive: String
    let runnerVersion: String
    let jobsProcessed: Int
    let avgExecutionMs: Int?
    let avgQueueWaitMs: Int?
    /// "host · version · 12 jobs · avg run 14s · avg wait 3s"; a missing value is
    /// left out rather than shown as a dash.
    let detailsText: String
    /// True when the runner reports a slot count, so the load track draws pips.
    let hasSlots: Bool
    let pips: [SlipDayPip]
    /// "2 of 4 busy" or "idle"; the plain count when the runner reports no slots.
    let loadLabel: String

    init(_ worker: AdminWorkerRow) {
        workerID = worker.workerID
        isOffline = worker.isOffline
        assignedJobs = worker.assignedJobs
        maxConcurrentJobs = worker.maxConcurrentJobs
        lastActive = worker.lastActive
        runnerVersion = worker.runnerVersion
        jobsProcessed = worker.jobsProcessed
        avgExecutionMs = worker.avgExecutionMs
        avgQueueWaitMs = worker.avgQueueWaitMs
        let jobs = "\(worker.jobsProcessed) \(worker.jobsProcessed == 1 ? "job" : "jobs")"
        var parts: [String] = []
        if !worker.hostname.isEmpty { parts.append(worker.hostname) }
        if !worker.runnerVersion.isEmpty { parts.append(worker.runnerVersion) }
        parts.append(jobs)
        if let run = worker.avgExecutionFormatted { parts.append("avg run \(run)") }
        if let wait = worker.avgQueueWaitFormatted { parts.append("avg wait \(wait)") }
        detailsText = parts.joined(separator: " · ")
        hasSlots = worker.maxConcurrentJobs > 0
        pips = Self.loadPips(assigned: worker.assignedJobs, slots: worker.maxConcurrentJobs)
        if worker.maxConcurrentJobs > 0 {
            loadLabel =
                worker.assignedJobs == 0
                ? "idle" : "\(worker.assignedJobs) of \(worker.maxConcurrentJobs) busy"
        } else {
            loadLabel = worker.assignedJobs == 0 ? "idle" : "\(worker.assignedJobs) busy"
        }
    }

    /// One pip per slot, busy ones first. `left` draws busy; once every slot is
    /// busy they all read `extra` (amber), the "at capacity" cue.
    static func loadPips(assigned: Int, slots: Int) -> [SlipDayPip] {
        guard slots > 0 else { return [] }
        let busy = min(max(assigned, 0), slots)
        if busy == slots { return Array(repeating: SlipDayPip(state: "extra"), count: slots) }
        return (0..<slots).map { SlipDayPip(state: $0 < busy ? "left" : "used") }
    }
}

struct AdminCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let isArchived: Bool
    let enrollmentMode: String
    let enrollmentCount: Int
    let assignmentCount: Int
    let submissionCount: Int
    let createdAt: String
    var brightspaceOrgUnitID: String?
    var brightspaceOrgUnitName: String?
    var brightspaceSyncEnabled: Bool
    /// The offering's term (docs/course-terms.md); all nil when none is
    /// recorded. Set through `withTerm(_:)`.
    var termYear: Int?
    var termSeason: String?
    var termLabel: String?
    var termSortValue: Int?

    /// This row with the term columns filled from `term`.
    func withTerm(_ term: AcademicTerm?) -> AdminCourseRow {
        var row = self
        row.termYear = term?.year
        row.termSeason = term?.season.rawValue
        row.termLabel = term?.displayName
        row.termSortValue = term?.ordinal
        return row
    }
}

struct AdminRunnerSummary: Encodable {
    let activeJobs: Int
    let maxJobs: Int
    let jobsProcessed: Int
    let avgExecutionFormatted: String?
    let avgQueueWaitFormatted: String?
    let avgOverheadFormatted: String?
    let avgCacheAcquireFormatted: String?
    let avgDownloadFormatted: String?
    let avgPrepFormatted: String?
    /// "<pct>% (<hits>/<total>)" over recent jobs with a recorded cache flag.
    /// `nil` when no recent job reported a `testSetupCacheHit` (e.g. runner is
    /// pre-v0.4.169 or only ran validation submissions).  When non-nil, this
    /// is the only direct signal that the LRU cache is actually paying off
    /// — compare hit-rate against `avgCacheAcquireFormatted` to confirm.
    let cacheHitRateFormatted: String?
    let passedCount: Int
    let failedCount: Int
    let errorCount: Int
    let timeoutCount: Int
}

struct AdminRunnerJobRow: Encodable {
    let submissionID: String
    let assignmentID: String?
    let username: String?
    let finalStatus: String
    let queueWaitMs: Int?
    let executionMs: Int?
    let queueWaitFormatted: String?
    let executionFormatted: String?
    let totalProcessingMs: Int?
    let totalProcessingFormatted: String?
    /// Bytes-on-disk for the per-job workspace, sampled just before
    /// cleanup. Sortable; the formatted variant carries the rendered
    /// "12.4 MB" / "850 KB" string.
    let workdirPeakBytes: Int?
    let workdirPeakFormatted: String?
    let completedAt: String?
    /// The submitting student's own seeded avatar; the row shows a grey tile and
    /// "No user" when the job has no user (a validation run, say).
    var avatar: AvatarPresentation?
    var hasAvatar: Bool = false
    /// The status as the pill words it, and the pill's class suffix
    /// ("open" passed, "danger" failed or errored, "preview" timed out).
    var statusLabel: String = ""
    var statusTier: String = "closed"
    /// "wait 1s · run 2s · total 3s · peak disk 12.0 MB" — missing parts left out.
    var detailsText: String = ""
    /// "hit the 10s limit" on a timed-out job whose limit is known; else empty.
    var limitText: String = ""
}

struct AdminRunnerSnapshotRow: Encodable {
    let recordedAt: String
    let activeJobs: Int
    let maxJobs: Int
    let activeJobsLabel: String
    let utilizationPercent: Int
    let lastPollAt: String?
}

/// One assignment as the Storage page draws it: its footprint as a share of the
/// whole, and as a bar sized against the largest row.
struct AdminStorageShareRow: Encodable, Sendable {
    let assignmentTitle: String
    let courseCode: String
    /// "suite 1.2 MB · submissions 3.4 MB · 12 submissions".
    let detailsText: String
    let totalFormatted: String
    /// This row's percent of the total on disk, for the label ("<1%" under one).
    let shareLabel: String
    /// The bar's width, 0...100, relative to the largest row so the biggest row
    /// always fills it and the rest read against it.
    let barPercent: Int

    /// Rows in the order given (largest first), with the share and bar worked
    /// out. `totalBytes` of zero falls back to the sum of the rows.
    static func rows(from assignments: [AdminAssignmentStorageRow], totalBytes: Int) -> [Self] {
        let denominator = totalBytes > 0 ? totalBytes : assignments.reduce(0) { $0 + $1.totalBytes }
        let largest = assignments.map(\.totalBytes).max() ?? 0
        return assignments.map { row in
            let share = denominator > 0 ? Double(row.totalBytes) / Double(denominator) * 100 : 0
            let label = row.totalBytes > 0 && share < 1 ? "<1%" : "\(Int(share.rounded()))%"
            let bar = largest > 0 ? Int((Double(row.totalBytes) / Double(largest) * 100).rounded()) : 0
            let count = "\(row.submissionCount) \(row.submissionCount == 1 ? "submission" : "submissions")"
            return AdminStorageShareRow(
                assignmentTitle: row.assignmentTitle,
                courseCode: row.courseCode,
                detailsText: "suite \(row.testSuiteFormatted) · submissions \(row.submissionsFormatted) · \(count)",
                totalFormatted: row.totalFormatted,
                shareLabel: label,
                barPercent: row.totalBytes > 0 ? max(bar, 1) : 0)
        }
    }
}

struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let workers: [AdminRunnerRow]
    let courses: [AdminCourseRow]
    /// Whether the course list is long enough to earn a filter box
    /// (`ListFilterPolicy`).
    let showCourseFilter: Bool
    let version: String
    /// Default (24h) activity series, JSON-encoded into the page so the chart
    /// renders before the first poll.  The client re-fetches GET /admin/activity
    /// when the window changes or on its refresh interval.
    let activityChart: ActivityChartData

    // Explicit initializer (rather than relying on the synthesized memberwise
    // one): under the CI build's batch/non-WMO mode the synthesized init's
    // symbol can fail to emit, producing an "undefined reference to
    // AdminContext.init(...)" link error in chickadee-server. A hand-written
    // init is emitted normally and sidesteps that. It also derives
    // `showCourseFilter` from the course count.
    init(
        currentUser: CurrentUserContext?,
        activeAdminTab: String,
        workers: [AdminRunnerRow],
        courses: [AdminCourseRow],
        version: String,
        activityChart: ActivityChartData
    ) {
        self.currentUser = currentUser
        self.activeAdminTab = activeAdminTab
        self.workers = workers
        self.courses = courses
        self.showCourseFilter = ListFilterPolicy.showsFilter(rowCount: courses.count)
        self.version = version
        self.activityChart = activityChart
    }
}

struct AdminUsersContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let users: [AdminUserRow]
    let userCount: Int
    let adminCount: Int
}

/// Context for the rows-only fragment of the runners table (`?fragment=rows`).
struct WorkerRowsFragmentContext: Encodable {
    let workers: [AdminRunnerRow]
}

/// Context for the rows-only fragment of the users table (`?fragment=rows`).
/// Carries exactly what `_user-rows.leaf` reads, so the fragment cannot start
/// depending on page-level state the poll does not compute.
struct UserRowsFragmentContext: Encodable {
    let users: [AdminUserRow]
}

/// One course as the admin pages name it, in an enrolled or enrollable list.
struct AdminCourseRef: Encodable {
    let id: String
    let code: String
    let name: String
    /// The offering's term, so two offerings of one code can be told apart.
    let termLabel: String?

    /// The code and term, "CS135 Fall 2026", for text built in Swift.
    var label: String { termLabel.map { "\(code) \($0)" } ?? code }
}

struct AdminMCPAccountRow: Encodable {
    let id: String
    let username: String
    let createdAt: String
    /// Courses this account is enrolled in — the only courses its tokens may
    /// touch (admins excepted). Empty means the account can do nothing.
    let enrolledCourses: [AdminCourseRef]
    /// "CS135 · CS136" for the details line; empty when the account has none.
    let coursesText: String
    /// Courses the account is not yet enrolled in, for the enrol picker.
    let enrollableCourses: [AdminCourseRef]
}

struct AdminMCPContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    /// True only when MCP is mounted, the signing authority is loaded, and the
    /// issuer/resource resolve — i.e. tokens can actually be minted.
    let enabled: Bool
    /// False in read_only mode: the page hides the read+write mint option and
    /// shows a read-only banner.
    let writeAllowed: Bool
    let issuer: String?
    let resource: String?
    let tokenTTLSeconds: Int
    /// True only in local-auth mode: manual `mcp` service accounts are the
    /// mechanism there. With SSO active, instructors authorize agents via the
    /// browser flow instead, so the service-account UI is hidden.
    let showServiceAccounts: Bool
    let accounts: [AdminMCPAccountRow]
    /// All courses, for the per-account enrollment picker.
    let allCourses: [AdminCourseRef]
    /// Browser-flow OAuth grants (all of them — admin view), with revoke.
    let grants: [AgentGrantRow]
    /// Set immediately after a mint so the page can show the token exactly once.
    let mintedToken: String?
    let mintedFor: String?
    let mintedScopes: String?
    /// A short error key surfaced as a banner (e.g. "username_taken").
    let error: String?
    /// The mode pill: "Read/write", "Read-only" or "Inactive".
    let modeLabel: String
    /// Token lifetime in words ("1 hour", "30 minutes").
    let tokenLifetimeText: String
}

struct AdminStoragePageContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let storage: AdminStorageContext
    let assignmentRows: [AdminStorageShareRow]
}

struct AdminUserDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let targetUserID: String
    let displayName: String?
    let username: String
    let role: String
    let enrolledCourses: [AdminCourseRef]
    let availableCourses: [AdminCourseRef]
}

struct AdminCourseDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let course: AdminCourseRow
    let enrolledUsers: [AdminCourseEnrolledUserRow]
    let assignments: [AdminCourseAssignmentRow]
    let isNew: Bool
    /// The new-course form, or a course's settings form.
    let courseForm: CourseFieldsContext
    /// The clone form; nil on the new-course page.
    var cloneForm: CourseFieldsContext?
    /// True when a person with no account can be added as staff: SSO adopts
    /// the placeholder on their first login. False under local sign-in only.
    var placeholderAllowed = false
    /// The staff form; nil on the new-course page.
    var staffForm: StaffFieldsContext?
    /// "Staff member added." after the staff form succeeds; `_flash` in the
    /// base layout renders it.
    var flashSuccess: String?
}

/// One snapshot drawn as a bar of the utilization chart.
struct AdminRunnerChartBar: Encodable {
    /// Bar height as a percent of the plot; a 0% snapshot keeps a 2% stub so its
    /// slot is visible.
    let heightPercent: Int
    /// "idle" (grey stub), "busy" (teal) or "full" (amber, every slot in use).
    let state: String
    let title: String
}

struct AdminRunnerDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let runner: AdminWorkerRow
    let tags: [String]
    let summary: AdminRunnerSummary
    let recentJobs: [AdminRunnerJobRow]
    let snapshots: [AdminRunnerSnapshotRow]
    let firstSeenAt: String?
    /// The snapshots oldest to newest, one bar each.
    let chartBars: [AdminRunnerChartBar]
    /// Three or four evenly spaced clock times for the chart's x-axis.
    let chartLabels: [String]
    /// "12m 3s" — how long since the last heartbeat; empty while the runner is online.
    let offlineForText: String
}

struct AdminCourseEnrolledUserRow: Encodable {
    let id: String
    let username: String
    let displayName: String?
    let role: String
    /// The person's own seeded avatar, at the roster size. `hasAvatar` is the
    /// flat flag the template branches on (a bare optional in a Leaf
    /// conditional is unreliable).
    var avatar: AvatarPresentation?
    var hasAvatar: Bool = false
    var roleSelect: RoleSelectCell?
}

struct AdminCourseAssignmentRow: Encodable {
    let id: String  // publicID — used in /instructor/:id/... URLs
    let title: String
    let dueAt: String?
    let isOpen: Bool
    let visibility: String  // "closed" | "preview" | "open"
}

struct AdminAlertsRuleRow: Encodable {
    let rule: String
    let humanReadable: String
    let isFiring: Bool
    let lastFiredAt: String?
    /// The condition the rule fires on, from the live configuration.
    let thresholdText: String
}

struct AdminAlertsContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let enabled: Bool
    let webhookURL: String
    let webhookURLFromEnvironment: Bool
    let checkIntervalSeconds: Int
    let cooldownSeconds: Int
    let runnerOfflineSeconds: Int
    let queueDepthThreshold: Int
    let oldestPendingSeconds: Int
    let errorRatePercent: Int
    let rules: [AdminAlertsRuleRow]
    /// The webhook shortened from the middle for display; "Not set" when empty.
    let webhookDisplay: String
    /// The newest paged firing's time and result, or none yet.
    let hasLastDelivery: Bool
    let lastDeliveryISO: String
    let lastDeliveryResult: String
    /// Recent firings under their day headings, newest first.
    let firingDays: [DayGroup<AdminAlertFiringRow>]
    let firingCount: Int
    let flashSuccess: String?
    let flashError: String?
}

struct AdminAuditRow: Encodable {
    let timestamp: String
    /// Machine instant behind `timestamp`, so the WHEN cell can lead with a
    /// relative reading and keep the forensic one beneath it.
    let timestampISO: String
    let actor: String
    /// Coarse grouping (e.g. "Authentication", "MCP / agents").
    let category: String
    /// Human-readable action label (e.g. "MCP access authorized").
    let label: String
    /// Raw machine action identifier, shown as a secondary <code> line.
    let action: String
    let targetType: String?
    let targetID: String?
    let metadata: String
    let remoteAddr: String
    /// "ok" / "failed" — see `AuditAction.outcome`.
    let outcome: String
    /// The status-badge variant `outcome` renders as.
    let outcomeTier: String
    /// The instant itself, so rows can be grouped by day. Not rendered.
    let occurredAt: Date
    /// Time of day in the display zone, in mono, under the day heading.
    let clockText: String
    /// "admin", "auth", "agent" or "other": picks the tile.
    let categoryKey: String
    let tileKind: String
    let iconHref: String

    private enum CodingKeys: String, CodingKey {
        case timestamp, timestampISO, actor, category, label, action, targetType, targetID
        case metadata, remoteAddr, outcome, outcomeTier, clockText, categoryKey, tileKind, iconHref
    }
}

/// How an audit entry's category maps to its tile: deployment-admin actions get
/// a shield, sign-ins a key, agent activity a chip, everything else a neutral tile.
enum AuditCategoryTile {
    static func tile(forCategory category: String) -> (key: String, kind: String, icon: String) {
        switch category {
        case AuditCategory.users.rawValue, AuditCategory.courses.rawValue,
            AuditCategory.runner.rawValue, AuditCategory.brightspace.rawValue,
            AuditCategory.lti.rawValue, AuditCategory.github.rawValue:
            return ("admin", "outline", "#i-shield")
        case AuditCategory.authentication.rawValue:
            return ("auth", "slides", "#i-key")
        case AuditCategory.mcp.rawValue:
            return ("agent", "notebook", "#i-cpu")
        default:
            return ("other", "link", "#i-link")
        }
    }
}

struct AdminAuditContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let rows: [AdminAuditRow]
    /// The same rows under day headings, newest first.
    let days: [DayGroup<AdminAuditRow>]
    /// Available action filters (grouped label shown to the admin).
    let actionOptions: [SelectOption]
    /// The actor substring currently filtered on (echoed back into the input).
    let filterActor: String
    /// True when any filter is active — drives the "Clear filters" affordance.
    let filtered: Bool
    /// Total entries matching the current filter (may exceed the 200 shown).
    let matchCount: Int
}

/// One archived course on the retention report.
struct AdminRetentionRow: Encodable {
    let id: String
    let code: String
    let name: String
    /// "Fall 2026", or nil when the course records no term.
    let termLabel: String?
    /// Formatted archival timestamp, or "—" if unknown (legacy rows).
    let archivedAt: String
    /// ISO archival timestamp for client-side date sorting ("" if unknown).
    let archivedAtISO: String
    /// Formatted `archivedAt + retentionDays`, or "—" if archival is unknown.
    let purgeEligibleAt: String
    /// ISO purge-eligible timestamp for client-side date sorting ("" if unknown).
    let purgeEligibleAtISO: String
    let submissionCount: Int
    /// True once the retention window has elapsed — the Delete button is only
    /// rendered (and the server only honours a delete) when this is true.
    /// Restore (unarchive) is offered regardless of this flag.
    let isDeletable: Bool
}

struct AdminRetentionContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let retentionDays: Int
    let rows: [AdminRetentionRow]
    /// How many of `rows` are currently past the retention window and eligible
    /// for permanent deletion (drives the summary line).
    let deletableCount: Int
    let flashSuccess: String?
    let flashError: String?
}

// MARK: - LTI (docs/lti-1-3.md slice 1b)

struct AdminLTIContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    /// False when `PUBLIC_BASE_URL` is unset: the tool URLs are paths only.
    let baseURLConfigured: Bool
    let loginURL: String
    let launchURL: String
    let jwksURL: String
    let platforms: [AdminLTIPlatformRow]
    /// Platforms with launches switched on, for the title's note.
    let enabledPlatformCount: Int
    /// True when a registration failed validation, so the form reopens with
    /// what the admin typed, or when no platform exists yet, so the only way
    /// forward is already open.
    let newPlatformOpen: Bool
    let newFields: LTIPlatformFieldsContext
    let flashSuccess: String?
    let flashError: String?
}

struct AdminLTIPlatformRow: Encodable {
    let id: String
    let displayName: String
    let issuer: String
    let clientID: String
    let deploymentCount: Int
    let enabled: Bool
    /// True when an edit of this row failed validation.
    let editOpen: Bool
    let fields: LTIPlatformFieldsContext
}

/// The sub-context of the shared platform field set: a unique id prefix per
/// form, so the add form and every edit form can sit on one page.
struct LTIPlatformFieldsContext: Encodable {
    let idPrefix: String
    let form: LTIPlatformForm
    /// A validation error for this form, shown inside it rather than at the
    /// top of the page, which can be a whole table away.
    var error: String?
}

// MARK: - GitHub (docs/github-submissions.md slice 1)

struct AdminGitHubContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    /// False when `PUBLIC_BASE_URL` is unset: the manifest needs absolute URLs.
    let baseURLConfigured: Bool
    /// The registered App, or nil when none is registered.
    let app: AdminGitHubAppDetails?
    /// True when an App is registered but its secrets file is missing or
    /// unreadable (#1771); `secretsMissing` says which, and `secretsPath` is
    /// the file the admin must restore. Empty when there is no problem.
    let secretsUnavailable: Bool
    let secretsMissing: Bool
    let secretsPath: String
    /// The App's three options and whether GitHub grants each, read when the
    /// page renders (#1776). Empty when there is no App, its secrets are
    /// unavailable, or GitHub did not answer.
    let capabilities: [GitHubCapabilityRow]
    /// True when at least one option is not granted.
    let capabilitiesIncomplete: Bool
    /// True when the App's secrets are readable but GitHub did not say what
    /// the App may do.
    let capabilitiesUnknown: Bool
    /// The manifest form, or nil when an App is registered or the form cannot
    /// be built.
    let creation: GitHubAppCreationContext?
    /// The organization the admin typed, so the field keeps it.
    let organization: String
    /// True when an option was set, so the disclosure stays open.
    let organizationOpen: Bool
    /// True when the manifest asks for the course-repository permissions.
    let courseRepositories: Bool
    /// True when the manifest asks GitHub to deliver push events.
    let pushEvents: Bool
    /// True when the manifest asks to post commit statuses.
    let commitStatuses: Bool
    let flashSuccess: String?
    let flashError: String?
}

struct AdminGitHubAppDetails: Encodable {
    let name: String
    let slug: String
    let appID: Int
    let clientID: String
    let owner: String?
    let htmlURL: String

    init(app: APIGitHubApp) {
        name = app.name
        slug = app.slug
        appID = app.appID
        clientID = app.clientID
        owner = app.ownerLogin
        htmlURL = app.htmlURL
    }
}

/// The form that posts the manifest to GitHub.
struct GitHubAppCreationContext: Encodable {
    let actionURL: String
    let manifestJSON: String
    /// "your GitHub account" or "the organization <name>".
    let ownerLabel: String
}
