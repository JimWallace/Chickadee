// APIServer/routes.swift

import Vapor

func routes(_ app: Application) throws {
    let sessionAuth = UserSessionAuthenticator()

    // MARK: - Public routes (no auth required)

    try app.register(collection: AuthRoutes())
    // Worker result reporting is called by the worker daemon, not the browser.
    // It uses its own workerID for identification (Phase 7 will add worker tokens).
    try app.register(collection: ResultRoutes())

    // MARK: - Any authenticated user

    let auth = app.grouped(sessionAuth, RoleMiddleware(required: .authenticated))
    try auth.register(collection: WebRoutes())
    try auth.register(collection: SubmissionDownloadRoute())
    try auth.register(collection: SubmissionQueryRoutes())
    try auth.register(collection: BrowserResultRoutes())
    // TestSetupRoutes is in the auth group so students can fetch/download notebooks.
    // Instructor-only handlers (upload, zip-download, save) guard themselves inline.
    try auth.register(collection: TestSetupRoutes())

    // MARK: - Instructor or admin only

    let instructor = app.grouped(sessionAuth, RoleMiddleware(required: .instructor))
    try instructor.register(collection: AssignmentRoutes())
    // Worker job polling is instructor-tier: only the server operator runs workers.
    try instructor.register(collection: SubmissionRoutes())

    // MARK: - Admin only

    let admin = app.grouped(sessionAuth, RoleMiddleware(required: .admin))
    try admin.register(collection: AdminRoutes())
}
