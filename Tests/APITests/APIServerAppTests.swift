import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

// Tests that mutate process env vars must wrap their body in
// `withTestEnvironment`, which acquires the shared async env lock.  The
// same lock serializes against `configureTestDatabase`'s env read and
// against every other env-touching suite, so the SQLite api-tests job
// doesn't see a transient `TEST_DATABASE_BACKEND=postgres` from a
// concurrently-running test.
@Suite(.serialized)
struct APIServerAppTests {

    private func makeTempDir(named prefix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func resolvedAuthModeDefaultsToSSO() {
        #expect(resolvedAuthMode(requestedMode: nil, nonSSOModesEnabled: false) == .sso)
        #expect(resolvedAuthMode(requestedMode: .sso, nonSSOModesEnabled: false) == .sso)
    }

    @Test func resolvedAuthModeRejectsLocalAndDualWithoutFlag() {
        #expect(resolvedAuthMode(requestedMode: .local, nonSSOModesEnabled: false) == .sso)
        #expect(resolvedAuthMode(requestedMode: .dual, nonSSOModesEnabled: false) == .sso)
    }

    @Test func resolvedAuthModeHonorsNonSSOFlag() {
        #expect(resolvedAuthMode(requestedMode: .local, nonSSOModesEnabled: true) == .local)
        #expect(resolvedAuthMode(requestedMode: .dual, nonSSOModesEnabled: true) == .dual)
    }

    @Test func securityConfigurationUsesHTTPSDefaultsForSSO() async throws {
        try await withTestEnvironment([
            "PUBLIC_BASE_URL": "https://courses.example.edu",
            "ENFORCE_HTTPS": nil,
            "TRUST_X_FORWARDED_PROTO": nil,
            "SESSION_COOKIE_SECURE": nil,
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .sso)
            #expect(config.publicBaseURL?.absoluteString == "https://courses.example.edu")
            #expect(config.enforceHTTPS)
            #expect(config.trustForwardedProto)
            #expect(config.sessionCookieSecure)
        }
    }

    @Test func securityConfigurationUsesLocalDefaultsWithoutEnv() async throws {
        try await withTestEnvironment([
            "PUBLIC_BASE_URL": nil,
            "ENFORCE_HTTPS": nil,
            "TRUST_X_FORWARDED_PROTO": nil,
            "SESSION_COOKIE_SECURE": nil,
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)
            #expect(config.publicBaseURL == nil)
            #expect(!config.enforceHTTPS)
            #expect(config.trustForwardedProto)
            #expect(!config.sessionCookieSecure)
        }
    }

    // MARK: - Idle-warning window config

    @Test func idleWarningDefaultsTo120Seconds() async throws {
        try await withTestEnvironment([
            "SESSION_IDLE_TIMEOUT_MINUTES": nil,
            "SESSION_IDLE_WARNING_SECONDS": nil,
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)
            #expect(config.sessionIdleTimeoutSeconds == 30 * 60)
            #expect(config.sessionIdleWarningSeconds == 120)
        }
    }

    @Test func idleWarningHonoursCustomValue() async throws {
        try await withTestEnvironment([
            "SESSION_IDLE_TIMEOUT_MINUTES": "30",
            "SESSION_IDLE_WARNING_SECONDS": "300",
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)
            #expect(config.sessionIdleWarningSeconds == 300)
        }
    }

    @Test func idleWarningClampsBelowTimeout() async throws {
        // 1-minute ceiling (60 s) with a 120 s warning must clamp so the
        // warning can't swallow the whole window — at least a 5 s logout gap.
        try await withTestEnvironment([
            "SESSION_IDLE_TIMEOUT_MINUTES": "1",
            "SESSION_IDLE_WARNING_SECONDS": "120",
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)
            #expect(config.sessionIdleTimeoutSeconds == 60)
            #expect(config.sessionIdleWarningSeconds == 55)
        }
    }

    @Test func idleWarningDisabledWhenTimeoutDisabled() async throws {
        try await withTestEnvironment([
            "SESSION_IDLE_TIMEOUT_MINUTES": "0",
            "SESSION_IDLE_WARNING_SECONDS": "120",
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)
            #expect(config.sessionIdleTimeoutSeconds == 0)
            #expect(config.sessionIdleWarningSeconds == 0)
        }
    }

    // MARK: - Session cookie

    @Test func sessionCookieIsBrowserScoped() {
        // No expires/maxAge → the browser drops the cookie on close, so closing
        // the browser logs the user out.
        let cookie = chickadeeSessionCookie(sessionID: SessionID(string: "abc123"), isSecure: true)
        #expect(cookie.expires == nil)
        #expect(cookie.maxAge == nil)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.isSecure)
        #expect(cookie.string == "abc123")
    }

    @Test func sessionCookieUsesSameSiteNoneOverHTTPS() {
        // The MCP OAuth popup is opened by a cross-site opener (claude.ai), so the
        // login POST that resumes /oauth/authorize is cross-site. SameSite=None is
        // required for the session cookie to ride along on that POST (and it must
        // be Secure for browsers to accept None).
        let cookie = chickadeeSessionCookie(sessionID: SessionID(string: "abc123"), isSecure: true)
        #expect(cookie.sameSite == HTTPCookies.SameSitePolicy.none)
    }

    @Test func sessionCookieFallsBackToLaxWithoutSecure() {
        // Plain-HTTP dev: browsers reject SameSite=None without Secure, so fall
        // back to Lax so local development still logs in.
        let cookie = chickadeeSessionCookie(sessionID: SessionID(string: "abc123"), isSecure: false)
        #expect(cookie.sameSite == .lax)
        #expect(!cookie.isSecure)
    }

    @Test func parseSSOIdentityAllowlistNormalizesAndDeduplicates() {
        let values = parseSSOIdentityAllowlist(" Alice ;bob@example.com,\nALICE,  carol ")
        #expect(values == ["alice", "bob@example.com", "carol"])
    }

    @Test func extractWorkerSecretArgumentStripsFlagAndReturnsValue() throws {
        var env = try Environment.detect(arguments: [
            "/usr/bin/chickadee-server",
            "serve",
            "--worker-secret",
            " top-secret ",
            "--hostname",
            "127.0.0.1",
        ])

        let secret = extractWorkerSecretArgument(from: &env)

        #expect(secret == "top-secret")
        #expect(
            env.arguments == [
                "/usr/bin/chickadee-server",
                "serve",
                "--hostname",
                "127.0.0.1",
            ])
    }

    @Test func extractWorkerSecretArgumentSupportsEqualsSyntax() throws {
        var env = try Environment.detect(arguments: [
            "/usr/bin/chickadee-server",
            "--worker-secret=from-equals",
            "serve",
        ])

        let secret = extractWorkerSecretArgument(from: &env)

        #expect(secret == "from-equals")
        #expect(env.arguments == ["/usr/bin/chickadee-server", "serve"])
    }

    @Test func resolveStartupWorkerSecretPrefersCLIAndWritesItToDisk() throws {
        let dir = try makeTempDir(named: "apiserver-secret")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: " cli-secret ",
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        #expect(resolved == "cli-secret")
        #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == "cli-secret")
    }

    @Test func resolveStartupWorkerSecretPrefersEnvOverDisk() async throws {
        let dir = try makeTempDir(named: "apiserver-secret-env")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "old-disk-secret".write(
            to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": "env-secret",
            "WORKER_SHARED_SECRET": nil,
        ]) {
            let resolved = resolveStartupWorkerSecret(
                cliWorkerSecret: nil,
                workerSecretFilePath: secretPath,
                workerSecretWordlistPath: wordlistPath
            )

            #expect(resolved == "env-secret")
            #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == "old-disk-secret")
        }
    }

    @Test func resolveStartupWorkerSecretFallsBackToPersistedDiskSecret() async throws {
        let dir = try makeTempDir(named: "apiserver-secret-disk")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "disk-secret".write(
            to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": nil,
            "WORKER_SHARED_SECRET": nil,
        ]) {
            let resolved = resolveStartupWorkerSecret(
                cliWorkerSecret: nil,
                workerSecretFilePath: secretPath,
                workerSecretWordlistPath: wordlistPath
            )

            #expect(resolved == "disk-secret")
        }
    }

    @Test func resolveStartupWorkerSecretGeneratesAndPersistsWhenUnset() async throws {
        let dir = try makeTempDir(named: "apiserver-secret-generate")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try (0..<2500).map { idx in "\(10000 + idx) word\(idx)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": nil,
            "WORKER_SHARED_SECRET": nil,
        ]) {
            let resolved = resolveStartupWorkerSecret(
                cliWorkerSecret: nil,
                workerSecretFilePath: secretPath,
                workerSecretWordlistPath: wordlistPath
            )

            #expect(!resolved.isEmpty)
            #expect(resolved.split(separator: "-").count == 3)
            #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == resolved)
        }
    }

    @Test func readAndWriteLocalRunnerAutoStartRoundTrip() throws {
        let dir = try makeTempDir(named: "apiserver-autostart")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/.local-runner-autostart"

        writeLocalRunnerAutoStartToDisk(enabled: true, filePath: path)
        #expect(readLocalRunnerAutoStartFromDisk(filePath: path) == true)

        writeLocalRunnerAutoStartToDisk(enabled: false, filePath: path)
        #expect(readLocalRunnerAutoStartFromDisk(filePath: path) == false)
    }

    @Test func workerSecretStoreUsesRuntimeOverrideBeforeEnvironment() async throws {
        try await withTestEnvironment(["RUNNER_SHARED_SECRET": "env-secret"]) {
            let store = WorkerSecretStore(initialOverride: nil)

            let initialSecret = await store.effectiveSecret()
            #expect(initialSecret == "env-secret")

            await store.setRuntimeOverride("runtime-secret")
            let overrideSecret = await store.effectiveSecret()
            #expect(overrideSecret == "runtime-secret")
        }
    }

    @Test func normalizedHostMapsWildcardBindingsToLocalhost() {
        #expect(normalizedHost("0.0.0.0") == "localhost")
        #expect(normalizedHost("::") == "localhost")
        #expect(normalizedHost(" example.com ") == "example.com")
    }

    @Test func environmentBoolRecognizesSupportedValuesAndRejectsInvalidInput() async throws {
        try await withTestEnvironment([
            "BOOL_TRUE": " YeS ",
            "BOOL_FALSE": "0",
            "BOOL_INVALID": "sometimes",
            "BOOL_EMPTY": "   ",
        ]) {
            #expect(environmentBool("BOOL_TRUE") == true)
            #expect(environmentBool("BOOL_FALSE") == false)
            #expect(environmentBool("BOOL_INVALID") == nil)
            #expect(environmentBool("BOOL_EMPTY") == nil)
            #expect(environmentBool("BOOL_MISSING") == nil)
        }
    }

    @Test func runnerSharedSecretFromEnvironmentPrefersPrimaryOverLegacy() async throws {
        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": "primary-secret",
            "WORKER_SHARED_SECRET": "legacy-secret",
        ]) {
            #expect(runnerSharedSecretFromEnvironment() == "primary-secret")
        }
        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": "   ",
            "WORKER_SHARED_SECRET": "legacy-secret",
        ]) {
            #expect(runnerSharedSecretFromEnvironment() == "legacy-secret")
        }
    }

    @Test func resolveStartupWorkerSecretIgnoresPlaceholderValues() async throws {
        let dir = try makeTempDir(named: "apiserver-secret-placeholder")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "cli-arg-secret".write(
            to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try (0..<2500).map { idx in "\(10000 + idx) word\(idx)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": "cli-arg-secret",
            "WORKER_SHARED_SECRET": nil,
        ]) {
            let resolved = resolveStartupWorkerSecret(
                cliWorkerSecret: "cli-arg-secret",
                workerSecretFilePath: secretPath,
                workerSecretWordlistPath: wordlistPath
            )

            #expect(resolved != "cli-arg-secret")
            #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == resolved)
        }
    }

    @Test func readLocalRunnerAutoStartTreatsFalseyAndMalformedValuesAsDisabled() throws {
        let dir = try makeTempDir(named: "apiserver-autostart-read")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/.local-runner-autostart"

        try "off".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        #expect(readLocalRunnerAutoStartFromDisk(filePath: path) == false)

        try "garbage".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        #expect(readLocalRunnerAutoStartFromDisk(filePath: path) == false)
    }

    @Test func loadDicewareWordsSkipsMalformedRowsAndTrimsTokens() throws {
        let dir = try makeTempDir(named: "apiserver-diceware")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/words.txt"
        try """
        11111 alpha
        invalid-line
        11112    beta
        11113
        11114   gamma delta

        """.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        #expect(loadDicewareWords(from: path) == ["alpha", "beta", "gamma delta"])
    }

    @Test func securityConfigurationHonorsExplicitEnvOverrides() async throws {
        try await withTestEnvironment([
            "PUBLIC_BASE_URL": "http://courses.example.edu",
            "ENFORCE_HTTPS": "false",
            "TRUST_X_FORWARDED_PROTO": "off",
            "SESSION_COOKIE_SECURE": "no",
        ]) {
            let config = AppSecurityConfiguration.fromEnvironment(authMode: .sso)

            #expect(config.publicBaseURL?.absoluteString == "http://courses.example.edu")
            #expect(!config.enforceHTTPS)
            #expect(!config.trustForwardedProto)
            #expect(!config.sessionCookieSecure)
        }
    }
}
