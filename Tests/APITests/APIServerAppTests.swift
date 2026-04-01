import Testing
@testable import chickadee_server
import Fluent
import Vapor
import Foundation

// Environment variable manipulation is global process state, so this suite
// runs its tests serially to prevent races between concurrent test instances.
@Suite(.serialized)
class APIServerAppTests {

    private var envBackup: [String: String?] = [:]

    deinit {
        for (key, value) in envBackup {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    private func setEnv(_ key: String, _ value: String?) {
        if envBackup[key] == nil {
            envBackup[key] = ProcessInfo.processInfo.environment[key]
        }
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }

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

    @Test func securityConfigurationUsesHTTPSDefaultsForSSO() {
        setEnv("PUBLIC_BASE_URL", "https://courses.example.edu")
        setEnv("ENFORCE_HTTPS", nil)
        setEnv("TRUST_X_FORWARDED_PROTO", nil)
        setEnv("SESSION_COOKIE_SECURE", nil)

        let config = AppSecurityConfiguration.fromEnvironment(authMode: .sso)

        #expect(config.publicBaseURL?.absoluteString == "https://courses.example.edu")
        #expect(config.enforceHTTPS)
        #expect(config.trustForwardedProto)
        #expect(config.sessionCookieSecure)
    }

    @Test func securityConfigurationUsesLocalDefaultsWithoutEnv() {
        setEnv("PUBLIC_BASE_URL", nil)
        setEnv("ENFORCE_HTTPS", nil)
        setEnv("TRUST_X_FORWARDED_PROTO", nil)
        setEnv("SESSION_COOKIE_SECURE", nil)

        let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)

        #expect(config.publicBaseURL == nil)
        #expect(!config.enforceHTTPS)
        #expect(config.trustForwardedProto)
        #expect(!config.sessionCookieSecure)
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
            "127.0.0.1"
        ])

        let secret = extractWorkerSecretArgument(from: &env)

        #expect(secret == "top-secret")
        #expect(env.arguments == [
            "/usr/bin/chickadee-server",
            "serve",
            "--hostname",
            "127.0.0.1"
        ])
    }

    @Test func extractWorkerSecretArgumentSupportsEqualsSyntax() throws {
        var env = try Environment.detect(arguments: [
            "/usr/bin/chickadee-server",
            "--worker-secret=from-equals",
            "serve"
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

    @Test func resolveStartupWorkerSecretPrefersEnvOverDisk() throws {
        let dir = try makeTempDir(named: "apiserver-secret-env")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "old-disk-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", "env-secret")
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: nil,
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        #expect(resolved == "env-secret")
        #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == "old-disk-secret")
    }

    @Test func resolveStartupWorkerSecretFallsBackToPersistedDiskSecret() throws {
        let dir = try makeTempDir(named: "apiserver-secret-disk")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "disk-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", nil)
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: nil,
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        #expect(resolved == "disk-secret")
    }

    @Test func resolveStartupWorkerSecretGeneratesAndPersistsWhenUnset() throws {
        let dir = try makeTempDir(named: "apiserver-secret-generate")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try (0..<2500).map { idx in "\(10000 + idx) word\(idx)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", nil)
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: nil,
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        #expect(!resolved.isEmpty)
        #expect(resolved.split(separator: "-").count == 3)
        #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == resolved)
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

    @Test func workerSecretStoreUsesRuntimeOverrideBeforeEnvironment() async {
        setEnv("RUNNER_SHARED_SECRET", "env-secret")
        let store = WorkerSecretStore(initialOverride: nil)

        let initialSecret = await store.effectiveSecret()
        #expect(initialSecret == "env-secret")

        await store.setRuntimeOverride("runtime-secret")
        let overrideSecret = await store.effectiveSecret()
        #expect(overrideSecret == "runtime-secret")
    }

    @Test func normalizedHostMapsWildcardBindingsToLocalhost() {
        #expect(normalizedHost("0.0.0.0") == "localhost")
        #expect(normalizedHost("::") == "localhost")
        #expect(normalizedHost(" example.com ") == "example.com")
    }

    @Test func environmentBoolRecognizesSupportedValuesAndRejectsInvalidInput() {
        setEnv("BOOL_TRUE", " YeS ")
        setEnv("BOOL_FALSE", "0")
        setEnv("BOOL_INVALID", "sometimes")
        setEnv("BOOL_EMPTY", "   ")

        #expect(environmentBool("BOOL_TRUE") == true)
        #expect(environmentBool("BOOL_FALSE") == false)
        #expect(environmentBool("BOOL_INVALID") == nil)
        #expect(environmentBool("BOOL_EMPTY") == nil)
        #expect(environmentBool("BOOL_MISSING") == nil)
    }

    @Test func runnerSharedSecretFromEnvironmentPrefersPrimaryOverLegacy() {
        setEnv("RUNNER_SHARED_SECRET", "primary-secret")
        setEnv("WORKER_SHARED_SECRET", "legacy-secret")
        #expect(runnerSharedSecretFromEnvironment() == "primary-secret")

        setEnv("RUNNER_SHARED_SECRET", "   ")
        #expect(runnerSharedSecretFromEnvironment() == "legacy-secret")
    }

    @Test func resolveStartupWorkerSecretIgnoresPlaceholderValues() throws {
        let dir = try makeTempDir(named: "apiserver-secret-placeholder")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "cli-arg-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try (0..<2500).map { idx in "\(10000 + idx) word\(idx)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: wordlistPath), atomically: true, encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", "cli-arg-secret")
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: "cli-arg-secret",
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        #expect(resolved != "cli-arg-secret")
        #expect(readWorkerSecretFromDisk(workerSecretFilePath: secretPath) == resolved)
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

    @Test func securityConfigurationHonorsExplicitEnvOverrides() {
        setEnv("PUBLIC_BASE_URL", "http://courses.example.edu")
        setEnv("ENFORCE_HTTPS", "false")
        setEnv("TRUST_X_FORWARDED_PROTO", "off")
        setEnv("SESSION_COOKIE_SECURE", "no")

        let config = AppSecurityConfiguration.fromEnvironment(authMode: .sso)

        #expect(config.publicBaseURL?.absoluteString == "http://courses.example.edu")
        #expect(!config.enforceHTTPS)
        #expect(!config.trustForwardedProto)
        #expect(!config.sessionCookieSecure)
    }
}
