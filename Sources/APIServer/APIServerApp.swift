// APIServer/APIServerApp.swift

import CSRF
import Core
import Fluent
import Foundation
import Leaf
import Vapor

/// Library entry point invoked by the `chickadee-server` executable target.
/// Lives in `APIServer` (a library) so test targets can compile against the
/// same module without pulling in `@main` semantics.
public func runAPIServer() async throws {
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

func configure(_ app: Application, cliWorkerSecret: String?, authModeOverride: AuthMode? = nil) throws {
    let workDir = DirectoryConfiguration.detect().workingDirectory

    let appConfig = try resolveAppConfig(
        app: app,
        workDir: workDir,
        authModeOverride: authModeOverride
    )
    app.appConfig = appConfig

    try bootstrapAppDirectories(app, workDir: workDir, cliWorkerSecret: cliWorkerSecret)
    bootstrapAppMiddleware(app, appConfig: appConfig)
    try bootstrapAppServices(app, appConfig: appConfig)

    try routes(app)
}

/// Either resolves the env-derived `AppConfig`, or, if a test has preloaded
/// one via `app.preloadedAppConfig`, uses that verbatim (applying the
/// `authModeOverride` on top if any).  Both paths return a fully-formed
/// config ready to be stored on `app.appConfig`.
private func resolveAppConfig(
    app: Application,
    workDir: String,
    authModeOverride: AuthMode?
) throws -> AppConfig {
    if let preloaded = app.preloadedAppConfig {
        return authModeOverride.map { override in
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
    }
    let appConfig = try AppConfig.fromEnvironment(workDir: workDir, authModeOverride: authModeOverride)
    appConfig.logSummary(to: app.logger)
    return appConfig
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
