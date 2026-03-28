import XCTest
@testable import chickadee_server
import Vapor
import Foundation

final class APIServerAppTests: XCTestCase {

    private var envBackup: [String: String?] = [:]

    override func tearDown() {
        for (key, value) in envBackup {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        envBackup.removeAll()
        super.tearDown()
    }

    private func setEnv(_ key: String, _ value: String?) {
        if envBackup[key] == nil {
            envBackup[key] = ProcessInfo.processInfo.environment[key]
        }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    private func makeTempDir(named prefix: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testResolvedAuthModeDefaultsToSSO() {
        XCTAssertEqual(resolvedAuthMode(requestedMode: nil, nonSSOModesEnabled: false), .sso)
        XCTAssertEqual(resolvedAuthMode(requestedMode: .sso, nonSSOModesEnabled: false), .sso)
    }

    func testResolvedAuthModeRejectsLocalAndDualWithoutFlag() {
        XCTAssertEqual(resolvedAuthMode(requestedMode: .local, nonSSOModesEnabled: false), .sso)
        XCTAssertEqual(resolvedAuthMode(requestedMode: .dual, nonSSOModesEnabled: false), .sso)
    }

    func testResolvedAuthModeHonorsNonSSOFlag() {
        XCTAssertEqual(resolvedAuthMode(requestedMode: .local, nonSSOModesEnabled: true), .local)
        XCTAssertEqual(resolvedAuthMode(requestedMode: .dual, nonSSOModesEnabled: true), .dual)
    }

    func testSecurityConfigurationUsesHTTPSDefaultsForSSO() {
        setEnv("PUBLIC_BASE_URL", "https://courses.example.edu")
        setEnv("ENFORCE_HTTPS", nil)
        setEnv("TRUST_X_FORWARDED_PROTO", nil)
        setEnv("SESSION_COOKIE_SECURE", nil)

        let config = AppSecurityConfiguration.fromEnvironment(authMode: .sso)

        XCTAssertEqual(config.publicBaseURL?.absoluteString, "https://courses.example.edu")
        XCTAssertTrue(config.enforceHTTPS)
        XCTAssertTrue(config.trustForwardedProto)
        XCTAssertTrue(config.sessionCookieSecure)
    }

    func testSecurityConfigurationUsesLocalDefaultsWithoutEnv() {
        setEnv("PUBLIC_BASE_URL", nil)
        setEnv("ENFORCE_HTTPS", nil)
        setEnv("TRUST_X_FORWARDED_PROTO", nil)
        setEnv("SESSION_COOKIE_SECURE", nil)

        let config = AppSecurityConfiguration.fromEnvironment(authMode: .local)

        XCTAssertNil(config.publicBaseURL)
        XCTAssertFalse(config.enforceHTTPS)
        XCTAssertTrue(config.trustForwardedProto)
        XCTAssertFalse(config.sessionCookieSecure)
    }

    func testParseSSOIdentityAllowlistNormalizesAndDeduplicates() {
        let values = parseSSOIdentityAllowlist(" Alice ;bob@example.com,\nALICE,  carol ")
        XCTAssertEqual(values, ["alice", "bob@example.com", "carol"])
    }

    func testExtractWorkerSecretArgumentStripsFlagAndReturnsValue() throws {
        var env = try Environment.detect(arguments: [
            "/usr/bin/chickadee-server",
            "serve",
            "--worker-secret",
            " top-secret ",
            "--hostname",
            "127.0.0.1"
        ])

        let secret = extractWorkerSecretArgument(from: &env)

        XCTAssertEqual(secret, "top-secret")
        XCTAssertEqual(env.arguments, [
            "/usr/bin/chickadee-server",
            "serve",
            "--hostname",
            "127.0.0.1"
        ])
    }

    func testExtractWorkerSecretArgumentSupportsEqualsSyntax() throws {
        var env = try Environment.detect(arguments: [
            "/usr/bin/chickadee-server",
            "--worker-secret=from-equals",
            "serve"
        ])

        let secret = extractWorkerSecretArgument(from: &env)

        XCTAssertEqual(secret, "from-equals")
        XCTAssertEqual(env.arguments, ["/usr/bin/chickadee-server", "serve"])
    }

    func testResolveStartupWorkerSecretPrefersCLIAndWritesItToDisk() throws {
        let dir = try makeTempDir(named: "apiserver-secret")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath),
            atomically: true,
            encoding: .utf8
        )

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: " cli-secret ",
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        XCTAssertEqual(resolved, "cli-secret")
        XCTAssertEqual(readWorkerSecretFromDisk(workerSecretFilePath: secretPath), "cli-secret")
    }

    func testResolveStartupWorkerSecretPrefersEnvOverDisk() throws {
        let dir = try makeTempDir(named: "apiserver-secret-env")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "old-disk-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath),
            atomically: true,
            encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", "env-secret")
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: nil,
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        XCTAssertEqual(resolved, "env-secret")
        XCTAssertEqual(readWorkerSecretFromDisk(workerSecretFilePath: secretPath), "old-disk-secret")
    }

    func testResolveStartupWorkerSecretFallsBackToPersistedDiskSecret() throws {
        let dir = try makeTempDir(named: "apiserver-secret-disk")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "disk-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try "11111 alpha\n11112 beta\n11113 gamma\n".write(
            to: URL(fileURLWithPath: wordlistPath),
            atomically: true,
            encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", nil)
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: nil,
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        XCTAssertEqual(resolved, "disk-secret")
    }

    func testResolveStartupWorkerSecretGeneratesAndPersistsWhenUnset() throws {
        let dir = try makeTempDir(named: "apiserver-secret-generate")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try (0..<2500).map { idx in "\(10000 + idx) word\(idx)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: wordlistPath),
            atomically: true,
            encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", nil)
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: nil,
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        XCTAssertFalse(resolved.isEmpty)
        XCTAssertEqual(resolved.split(separator: "-").count, 3)
        XCTAssertEqual(readWorkerSecretFromDisk(workerSecretFilePath: secretPath), resolved)
    }

    func testReadAndWriteLocalRunnerAutoStartRoundTrip() throws {
        let dir = try makeTempDir(named: "apiserver-autostart")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/.local-runner-autostart"

        writeLocalRunnerAutoStartToDisk(enabled: true, filePath: path)
        XCTAssertEqual(readLocalRunnerAutoStartFromDisk(filePath: path), true)

        writeLocalRunnerAutoStartToDisk(enabled: false, filePath: path)
        XCTAssertEqual(readLocalRunnerAutoStartFromDisk(filePath: path), false)
    }

    func testWorkerSecretStoreUsesRuntimeOverrideBeforeEnvironment() async {
        setEnv("RUNNER_SHARED_SECRET", "env-secret")
        let store = WorkerSecretStore(initialOverride: nil)

        let initialSecret = await store.effectiveSecret()
        XCTAssertEqual(initialSecret, "env-secret")

        await store.setRuntimeOverride("runtime-secret")
        let overrideSecret = await store.effectiveSecret()
        XCTAssertEqual(overrideSecret, "runtime-secret")
    }

    func testNormalizedHostMapsWildcardBindingsToLocalhost() {
        XCTAssertEqual(normalizedHost("0.0.0.0"), "localhost")
        XCTAssertEqual(normalizedHost("::"), "localhost")
        XCTAssertEqual(normalizedHost(" example.com "), "example.com")
    }

    func testShouldLaunchLocalRunnerViaBinaryRejectsStaleRunnerBinary() throws {
        let dir = try makeTempDir(named: "apiserver-runner-launch-stale")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let buildDir = URL(fileURLWithPath: dir).appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let runnerPath = buildDir.appendingPathComponent("chickadee-runner").path
        let serverPath = buildDir.appendingPathComponent("chickadee-server").path
        XCTAssertTrue(FileManager.default.createFile(atPath: runnerPath, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: serverPath, contents: Data()))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: runnerPath
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: serverPath
        )

        XCTAssertFalse(shouldLaunchLocalRunnerViaBinary(workDir: dir + "/", runnerBinaryPath: runnerPath))
    }

    func testShouldLaunchLocalRunnerViaBinaryAcceptsFreshRunnerBinary() throws {
        let dir = try makeTempDir(named: "apiserver-runner-launch-fresh")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let buildDir = URL(fileURLWithPath: dir).appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let runnerPath = buildDir.appendingPathComponent("chickadee-runner").path
        let serverPath = buildDir.appendingPathComponent("chickadee-server").path
        XCTAssertTrue(FileManager.default.createFile(atPath: runnerPath, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: serverPath, contents: Data()))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: 300)],
            ofItemAtPath: runnerPath
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: serverPath
        )

        XCTAssertTrue(shouldLaunchLocalRunnerViaBinary(workDir: dir + "/", runnerBinaryPath: runnerPath))
    }

    func testEnvironmentBoolRecognizesSupportedValuesAndRejectsInvalidInput() {
        setEnv("BOOL_TRUE", " YeS ")
        setEnv("BOOL_FALSE", "0")
        setEnv("BOOL_INVALID", "sometimes")
        setEnv("BOOL_EMPTY", "   ")

        XCTAssertEqual(environmentBool("BOOL_TRUE"), true)
        XCTAssertEqual(environmentBool("BOOL_FALSE"), false)
        XCTAssertNil(environmentBool("BOOL_INVALID"))
        XCTAssertNil(environmentBool("BOOL_EMPTY"))
        XCTAssertNil(environmentBool("BOOL_MISSING"))
    }

    func testRunnerSharedSecretFromEnvironmentPrefersPrimaryOverLegacy() {
        setEnv("RUNNER_SHARED_SECRET", "primary-secret")
        setEnv("WORKER_SHARED_SECRET", "legacy-secret")
        XCTAssertEqual(runnerSharedSecretFromEnvironment(), "primary-secret")

        setEnv("RUNNER_SHARED_SECRET", "   ")
        XCTAssertEqual(runnerSharedSecretFromEnvironment(), "legacy-secret")
    }

    func testResolveStartupWorkerSecretIgnoresPlaceholderValues() throws {
        let dir = try makeTempDir(named: "apiserver-secret-placeholder")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretPath = dir + "/.worker-secret"
        let wordlistPath = dir + "/words.txt"
        try "cli-arg-secret".write(to: URL(fileURLWithPath: secretPath), atomically: true, encoding: .utf8)
        try (0..<2500).map { idx in "\(10000 + idx) word\(idx)" }.joined(separator: "\n").write(
            to: URL(fileURLWithPath: wordlistPath),
            atomically: true,
            encoding: .utf8
        )
        setEnv("RUNNER_SHARED_SECRET", "cli-arg-secret")
        setEnv("WORKER_SHARED_SECRET", nil)

        let resolved = resolveStartupWorkerSecret(
            cliWorkerSecret: "cli-arg-secret",
            workerSecretFilePath: secretPath,
            workerSecretWordlistPath: wordlistPath
        )

        XCTAssertNotEqual(resolved, "cli-arg-secret")
        XCTAssertEqual(readWorkerSecretFromDisk(workerSecretFilePath: secretPath), resolved)
    }

    func testReadLocalRunnerAutoStartTreatsFalseyAndMalformedValuesAsDisabled() throws {
        let dir = try makeTempDir(named: "apiserver-autostart-read")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/.local-runner-autostart"

        try "off".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        XCTAssertEqual(readLocalRunnerAutoStartFromDisk(filePath: path), false)

        try "garbage".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        XCTAssertEqual(readLocalRunnerAutoStartFromDisk(filePath: path), false)
    }

    func testLoadDicewareWordsSkipsMalformedRowsAndTrimsTokens() throws {
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

        XCTAssertEqual(loadDicewareWords(from: path), ["alpha", "beta", "gamma delta"])
    }

    func testSecurityConfigurationHonorsExplicitEnvOverrides() {
        setEnv("PUBLIC_BASE_URL", "http://courses.example.edu")
        setEnv("ENFORCE_HTTPS", "false")
        setEnv("TRUST_X_FORWARDED_PROTO", "off")
        setEnv("SESSION_COOKIE_SECURE", "no")

        let config = AppSecurityConfiguration.fromEnvironment(authMode: .sso)

        XCTAssertEqual(config.publicBaseURL?.absoluteString, "http://courses.example.edu")
        XCTAssertFalse(config.enforceHTTPS)
        XCTAssertFalse(config.trustForwardedProto)
        XCTAssertFalse(config.sessionCookieSecure)
    }
}
