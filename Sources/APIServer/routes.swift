// APIServer/routes.swift

import CSRF
import Vapor

func routes(_ app: Application) throws {
    let sessionAuth = UserSessionAuthenticator()
    let csrf = CSRF()

    // MARK: - Public routes (no auth required)

    try app.register(collection: HealthRoutes())
    let loginRateLimit = LoginRateLimitMiddleware(
        configuration: app.loginRateLimitConfiguration
    )
    try app.grouped(csrf, loginRateLimit).register(collection: AuthRoutes())
    if app.authMode != .local {
        try app.register(
            collection: SSOAuthRoutes(configuredCallbackPath: app.appConfig.oidc.callbackPath)
        )
    }
    // Worker routes — authenticated by per-request HMAC signatures.
    // WorkerHMACAuthMiddleware validates X-Worker-Timestamp / X-Worker-Nonce /
    // X-Worker-Signature against the server's effective shared secret.
    let workerAuth = app.grouped(WorkerHMACAuthMiddleware())
    try workerAuth.register(collection: WorkerJobRoutes())
    try workerAuth.register(collection: WorkerArtifactRoutes())
    try workerAuth.register(collection: ResultRoutes())

    // MARK: - Any authenticated user

    let auth = app.grouped(sessionAuth, RoleMiddleware(required: .authenticated), csrf)
    try auth.register(collection: SessionRoutes())
    try auth.register(collection: WebRoutes())
    try auth.register(collection: EnrollmentRoutes())
    try auth.register(collection: AccountRoutes())
    try auth.register(collection: SubmissionDownloadRoute())
    try auth.register(collection: SubmissionQueryRoutes())
    try auth.register(collection: BrowserResultRoutes())
    try auth.register(collection: BrowserRunnerRoutes())
    try auth.register(collection: ClientDiagnosticsRoutes())
    try auth.register(collection: JupyterLiteContentsRoutes())
    // TestSetupRoutes is in the auth group so students can fetch/download notebooks.
    // Instructor-only handlers (upload, zip-download, save) guard themselves inline.
    try auth.register(collection: TestSetupRoutes())
    // Registered last so fixed-path routes always take precedence.
    try auth.register(collection: VanityURLRoutes())

    // MARK: - Instructor or admin only

    let instructor = app.grouped(sessionAuth, RoleMiddleware(required: .instructor), csrf)
    try instructor.register(collection: InstructorDashboardRoutes())
    try instructor.register(collection: DraftAssignmentRoutes())
    try instructor.register(collection: PublishedAssignmentRoutes())
    try instructor.register(collection: CourseAdminRoutes())
    try instructor.register(collection: StudentCourseRoutes())
    try instructor.register(collection: MarmosetImportRoutes())
    // Worker job polling is instructor-tier: only the server operator runs workers.
    try instructor.register(collection: SubmissionRoutes())
    try instructor.register(collection: UWDatesRoute())

    // MARK: - Admin only

    let admin = app.grouped(sessionAuth, RoleMiddleware(required: .admin), csrf)
    try admin.register(collection: AdminRoutes())
    try admin.register(collection: InternalMetricsRoutes())
    try admin.register(collection: CourseBundleRoutes())

    // MARK: - MCP (content authoring)

    // Bearer-gated /mcp transport + unauthenticated OAuth discovery metadata.
    // Mounted only when MCP_ENABLED; a no-op otherwise.
    try registerMCPRoutes(app)
}
