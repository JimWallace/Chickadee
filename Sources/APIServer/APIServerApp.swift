// APIServer/APIServerApp.swift

import CSRF
import Core
import Fluent
import Foundation
import Leaf
import Vapor

@main
struct APIServerApp {
    static func main() async throws {
        var env = try Environment.detect()
        let cliWorkerSecret = extractWorkerSecretArgument(from: &env)
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        app.logger.info("Starting chickadee-server v\(ChickadeeVersion.current)")

        do {
            try configure(app, cliWorkerSecret: cliWorkerSecret)

            // Load OIDC configuration after configure() so app.client is ready.
            if app.authMode != .local {
                let oidcConfig = try await OIDCConfiguration.load(from: app)
                app.oidcConfig = oidcConfig
            }

            try await app.execute()
        } catch {
            await app.localRunnerManager.stopIfRunning(logger: app.logger)
            try await app.asyncShutdown()
            throw error
        }

        await app.localRunnerManager.stopIfRunning(logger: app.logger)
        try await app.asyncShutdown()
    }
}

func configure(_ app: Application, cliWorkerSecret: String?, authModeOverride: AuthMode? = nil) throws {
    let workDir = DirectoryConfiguration.detect().workingDirectory
    let workerSecretFile = workDir + ".worker-secret"
    let workerSecretWordlistFile = workDir + "Resources/wordlists/eff_large_wordlist.txt"
    let localRunnerAutoStartFile = workDir + ".local-runner-autostart"
    let alertWebhookURLFile = workDir + ".alert-webhook-url"

    let appConfig: AppConfig
    if let preloaded = app.preloadedAppConfig {
        // Test seam: use the caller-supplied config verbatim, with the
        // requested AuthMode override applied on top if any.
        appConfig =
            authModeOverride.map { override in
                var auth = preloaded.auth
                auth = AuthConfig(
                    mode: override,
                    requestedMode: auth.requestedMode,
                    nonSSOModesEnabled: auth.nonSSOModesEnabled,
                    ssoAdminUsers: auth.ssoAdminUsers,
                    ssoInstructorUsers: auth.ssoInstructorUsers
                )
                return AppConfig(
                    auth: auth,
                    oidc: preloaded.oidc,
                    security: preloaded.security,
                    scanMode: preloaded.scanMode,
                    database: preloaded.database,
                    lockout: preloaded.lockout,
                    workers: preloaded.workers,
                    brightspace: preloaded.brightspace,
                    diagnostics: preloaded.diagnostics,
                    alerts: preloaded.alerts
                )
            } ?? preloaded
    } else {
        appConfig = try AppConfig.fromEnvironment(workDir: workDir, authModeOverride: authModeOverride)
        appConfig.logSummary(to: app.logger)
    }
    app.appConfig = appConfig

    let authMode = appConfig.auth.mode
    let securityConfiguration = appConfig.security
    let scanModeConfiguration = appConfig.scanMode
    let loginRateLimitConfiguration = appConfig.lockout
    let ssoAdminUsers = appConfig.auth.ssoAdminUsers
    let ssoInstructorUsers = appConfig.auth.ssoInstructorUsers

    // MARK: - Directories

    let resultsDir = workDir + "results/"
    let setupsDir = workDir + "testsetups/"
    let submissionsDir = workDir + "submissions/"

    for dir in [resultsDir, setupsDir, submissionsDir] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    app.storage[ResultsDirectoryKey.self] = resultsDir
    app.storage[TestSetupsDirectoryKey.self] = setupsDir
    app.storage[SubmissionsDirectoryKey.self] = submissionsDir
    app.storage[WorkerSecretFilePathKey.self] = workerSecretFile
    app.storage[LocalRunnerAutoStartFilePathKey.self] = localRunnerAutoStartFile
    app.storage[ServerHealthAlertWebhookURLFilePathKey.self] = alertWebhookURLFile
    let startupWorkerSecret = resolveStartupWorkerSecret(
        cliWorkerSecret: cliWorkerSecret,
        workerSecretFilePath: workerSecretFile,
        workerSecretWordlistPath: workerSecretWordlistFile
    )
    let localRunnerAutoStartEnabled =
        readLocalRunnerAutoStartFromDisk(
            filePath: localRunnerAutoStartFile
        ) ?? false
    app.storage[WorkerClaimQueueKey.self] = WorkerClaimQueue()
    app.storage[WorkerSecretStoreKey.self] = WorkerSecretStore(initialOverride: startupWorkerSecret)
    app.storage[WorkerActivityStoreKey.self] = WorkerActivityStore()
    app.storage[LocalRunnerAutoStartStoreKey.self] = LocalRunnerAutoStartStore(
        initialEnabled: localRunnerAutoStartEnabled
    )
    app.storage[LocalRunnerManagerKey.self] = LocalRunnerManager()
    app.storage[AuthModeKey.self] = authMode
    app.storage[SecurityConfigurationKey.self] = securityConfiguration
    app.storage[ScanModeConfigurationKey.self] = scanModeConfiguration
    app.storage[LoginRateLimitConfigurationKey.self] = loginRateLimitConfiguration
    app.storage[SSOAdminUsersKey.self] = ssoAdminUsers
    app.storage[SSOInstructorUsersKey.self] = ssoInstructorUsers
    app.authProvider = LocalAuthProvider()

    // MARK: - Sessions (Fluent-backed; persisted in the database)

    app.sessions.use(.fluent)
    var sessionConfig = app.sessions.configuration
    sessionConfig.cookieFactory = { sessionID in
        HTTPCookies.Value(
            string: sessionID.string,
            expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 7),  // one week
            maxAge: nil,
            domain: nil,
            path: "/",
            isSecure: securityConfiguration.sessionCookieSecure,
            isHTTPOnly: true,
            sameSite: .lax
        )
    }
    app.sessions.configuration = sessionConfig
    // Error page middleware must be outermost so it catches errors from all
    // subsequent middleware and route handlers.
    app.middleware.use(LeafErrorMiddleware())
    if securityConfiguration.enforceHTTPS {
        app.middleware.use(HTTPSRedirectMiddleware(configuration: securityConfiguration))
    }
    app.middleware.use(app.sessions.middleware)
    app.middleware.use(UserSessionAuthenticator())
    app.middleware.use(UserActivityMiddleware(debounceWindow: 60))
    app.middleware.use(UserFileNamespaceMiddleware())
    // Scan-mode seatbelt: when SCAN_MODE=true is set in the environment, the
    // middleware 503s POSTs against destructive routes (submissions, test-setup
    // uploads, retests, user delete/role) so an in-progress vulnerability scan
    // can crawl the app without polluting prod data or fanning out work.
    if scanModeConfiguration.enabled {
        app.logger.warning(
            "SCAN_MODE=true — destructive POST endpoints are returning 503. Disable after the scan window."
        )
    }
    app.middleware.use(ScanModeMiddleware(configuration: scanModeConfiguration))
    // Allow notebook uploads from the assignment-creation flow.
    app.routes.defaultMaxBodySize = "10mb"

    // MARK: - Views + static files

    app.views.use(.leaf)
    app.leaf.tags["csrfFormField"] = CSRFFormFieldTag()
    app.leaf.tags["csrfToken"] = CSRFTokenTag()
    app.leaf.tags["appVersion"] = AppVersionTag()
    app.leaf.tags["rawJSON"] = RawJSONTag()
    // FileMiddleware is registered first so static files are served directly.
    // It short-circuits the responder chain (returns without calling next), so
    // middleware registered after it only runs for dynamic Leaf-rendered pages.
    // This is intentional: JupyterLite's static files must NOT receive COEP
    // require-corp because JupyterLite's service worker produces synthetic
    // responses (virtual filesystem, contents API) that lack Cross-Origin-
    // Resource-Policy headers.  COEP on the page would block those responses
    // and prevent the app from initialising.  Modern Pyodide (0.27+) does not
    // require SharedArrayBuffer — it uses a service-worker-based synchronisation
    // fallback — so cross-origin isolation on the iframe document is unnecessary.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(COEPMiddleware())
    // HSTS is set only when HTTPS enforcement is active. Pinning Strict-
    // Transport-Security against a dev http://localhost server would brick
    // local browsers; the enforceHTTPS gate matches HTTPSRedirectMiddleware.
    let hstsValue: String? =
        securityConfiguration.enforceHTTPS
        ? SecurityHeadersMiddleware.defaultStrictTransportSecurity
        : nil
    app.middleware.use(SecurityHeadersMiddleware(strictTransportSecurity: hstsValue))

    // MARK: - Database

    try configureDatabase(app, settings: appConfig.database)
    registerMigrations(on: app)

    try app.autoMigrate().wait()
    app.lifecycle.use(ObservabilityLifecycleHandler())
    app.lifecycle.use(AssignmentDeadlineLifecycleHandler())
    app.lifecycle.use(StuckSubmissionReaperLifecycleHandler())
    app.lifecycle.use(SessionReaperLifecycleHandler())
    app.lifecycle.use(ServerHealthAlertLifecycleHandler())

    // BrightSpace grade sync (only registered when env vars are present).
    if let bsConfig = appConfig.brightspace {
        app.brightSpaceSyncConfig = bsConfig
        app.brightSpaceClient = BrightSpaceAPIClient(config: bsConfig)
        app.lifecycle.use(BrightSpaceGradeSyncLifecycleHandler())
        app.logger.info("BrightSpace grade sync enabled (org unit IDs configured per-course)")
    }

    if authMode != .local {
        let nonSSOModesEnabled = appConfig.auth.nonSSOModesEnabled
        if !nonSSOModesEnabled {
            app.logger.info(
                "Default auth mode is SSO. Set ENABLE_NON_SSO_AUTH_MODES=true to allow local/dual AUTH_MODE values."
            )
        }
        if let requestedAuthMode = appConfig.auth.requestedMode,
            requestedAuthMode != .sso,
            !nonSSOModesEnabled
        {
            app.logger.warning(
                "AUTH_MODE=\(requestedAuthMode.rawValue) ignored because ENABLE_NON_SSO_AUTH_MODES is not enabled; using sso."
            )
        }
        if securityConfiguration.publicBaseURL == nil {
            app.logger.warning("AUTH_MODE is \(authMode.rawValue), but PUBLIC_BASE_URL is not set.")
        } else if securityConfiguration.publicBaseURL?.scheme?.lowercased() != "https" {
            let configured = securityConfiguration.publicBaseURL?.absoluteString ?? "(unset)"
            app.logger.warning("AUTH_MODE is \(authMode.rawValue), but PUBLIC_BASE_URL is not https: \(configured)")
        }
        if !securityConfiguration.sessionCookieSecure {
            app.logger.warning("AUTH_MODE is \(authMode.rawValue), but session cookies are not marked Secure.")
        }
        if appConfig.oidc.clientID == nil {
            app.logger.warning("AUTH_MODE is \(authMode.rawValue), but OIDC_CLIENT_ID is not set.")
        }
        if appConfig.oidc.clientSecret == nil {
            app.logger.warning("AUTH_MODE is \(authMode.rawValue), but OIDC_CLIENT_SECRET is not set.")
        }
    }

    // MARK: - Routes

    try routes(app)
}

// MARK: - Storage keys

struct ResultsDirectoryKey: StorageKey {
    typealias Value = String
}
struct TestSetupsDirectoryKey: StorageKey {
    typealias Value = String
}
struct SubmissionsDirectoryKey: StorageKey {
    typealias Value = String
}
struct WorkerSecretStoreKey: StorageKey {
    typealias Value = WorkerSecretStore
}
struct WorkerSecretFilePathKey: StorageKey {
    typealias Value = String
}
struct WorkerActivityStoreKey: StorageKey {
    typealias Value = WorkerActivityStore
}
struct LocalRunnerAutoStartFilePathKey: StorageKey {
    typealias Value = String
}
struct LocalRunnerAutoStartStoreKey: StorageKey {
    typealias Value = LocalRunnerAutoStartStore
}
struct LocalRunnerManagerKey: StorageKey {
    typealias Value = LocalRunnerManager
}
struct AuthModeKey: StorageKey {
    typealias Value = AuthMode
}
struct SecurityConfigurationKey: StorageKey {
    typealias Value = AppSecurityConfiguration
}
// Storage key for ScanModeConfigurationKey lives in ScanModeMiddleware.swift.
struct SSOAdminUsersKey: StorageKey {
    typealias Value = Set<String>
}
struct SSOInstructorUsersKey: StorageKey {
    typealias Value = Set<String>
}

extension Application {
    var authMode: AuthMode {
        get { storage[AuthModeKey.self] ?? .local }
        set { storage[AuthModeKey.self] = newValue }
    }

    var securityConfiguration: AppSecurityConfiguration {
        get { storage[SecurityConfigurationKey.self] ?? .default }
        set { storage[SecurityConfigurationKey.self] = newValue }
    }

    var ssoAdminUsers: Set<String> {
        get { storage[SSOAdminUsersKey.self] ?? [] }
        set { storage[SSOAdminUsersKey.self] = newValue }
    }

    var ssoInstructorUsers: Set<String> {
        get { storage[SSOInstructorUsersKey.self] ?? [] }
        set { storage[SSOInstructorUsersKey.self] = newValue }
    }
}

extension Application {
    var resultsDirectory: String {
        get { storage[ResultsDirectoryKey.self] ?? "results/" }
        set { storage[ResultsDirectoryKey.self] = newValue }
    }
    var testSetupsDirectory: String {
        get { storage[TestSetupsDirectoryKey.self] ?? "testsetups/" }
        set { storage[TestSetupsDirectoryKey.self] = newValue }
    }
    var submissionsDirectory: String {
        get { storage[SubmissionsDirectoryKey.self] ?? "submissions/" }
        set { storage[SubmissionsDirectoryKey.self] = newValue }
    }

    var workerSecretStore: WorkerSecretStore {
        get {
            if let existing = storage[WorkerSecretStoreKey.self] {
                return existing
            }
            let created = WorkerSecretStore()
            storage[WorkerSecretStoreKey.self] = created
            return created
        }
        set {
            storage[WorkerSecretStoreKey.self] = newValue
        }
    }

    var workerActivityStore: WorkerActivityStore {
        get {
            if let existing = storage[WorkerActivityStoreKey.self] {
                return existing
            }
            let created = WorkerActivityStore()
            storage[WorkerActivityStoreKey.self] = created
            return created
        }
        set {
            storage[WorkerActivityStoreKey.self] = newValue
        }
    }

    var workerSecretFilePath: String {
        get {
            storage[WorkerSecretFilePathKey.self]
                ?? (DirectoryConfiguration.detect().workingDirectory + ".worker-secret")
        }
        set { storage[WorkerSecretFilePathKey.self] = newValue }
    }

    var localRunnerAutoStartFilePath: String {
        get {
            storage[LocalRunnerAutoStartFilePathKey.self]
                ?? (DirectoryConfiguration.detect().workingDirectory + ".local-runner-autostart")
        }
        set { storage[LocalRunnerAutoStartFilePathKey.self] = newValue }
    }

    var localRunnerAutoStartStore: LocalRunnerAutoStartStore {
        get {
            if let existing = storage[LocalRunnerAutoStartStoreKey.self] {
                return existing
            }
            let created = LocalRunnerAutoStartStore(initialEnabled: false)
            storage[LocalRunnerAutoStartStoreKey.self] = created
            return created
        }
        set { storage[LocalRunnerAutoStartStoreKey.self] = newValue }
    }

    var localRunnerManager: LocalRunnerManager {
        get {
            if let existing = storage[LocalRunnerManagerKey.self] {
                return existing
            }
            let created = LocalRunnerManager()
            storage[LocalRunnerManagerKey.self] = created
            return created
        }
        set { storage[LocalRunnerManagerKey.self] = newValue }
    }
}
