import XCTest
@testable import chickadee_runner

final class RunnerDaemonConfigTests: XCTestCase {

    func testEmptyEnvironmentUsesDefaults() {
        let config = RunnerDaemonConfig.loadFromEnvironment([:])
        XCTAssertEqual(config, .defaults)
    }

    func testValidEnvVarsParsedAsExpected() {
        let env: [String: String] = [
            "RUNNER_CAPABILITY_DISCOVERY_ENABLED":     "false",
            "RUNNER_TEST_SETUP_CACHE_DIR":             "/var/cache/chickadee",
            "RUNNER_NETWORK_RETRY_ENABLED":            "no",
            "RUNNER_RETRY_BASE_DELAY_MS":              "250",
            "RUNNER_RETRY_MAX_DELAY_MS":               "60000",
            "RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS":     "9",
            "RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS": "12",
            "RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS":      "3",
        ]
        let config = RunnerDaemonConfig.loadFromEnvironment(env)
        XCTAssertEqual(config.capabilityDiscoveryEnabled,    false)
        XCTAssertEqual(config.testSetupCacheDir,             "/var/cache/chickadee")
        XCTAssertEqual(config.networkRetryEnabled,           false)
        XCTAssertEqual(config.retryBaseDelayMs,              250)
        XCTAssertEqual(config.retryMaxDelayMs,               60_000)
        XCTAssertEqual(config.heartbeatRetryMaxAttempts,     9)
        XCTAssertEqual(config.resultUploadRetryMaxAttempts,  12)
        XCTAssertEqual(config.downloadRetryMaxAttempts,      3)
    }

    func testBoolAcceptsCommonAliases() {
        for trueWord in ["1", "true", "True", "TRUE", "yes", "YES", "on", "ON"] {
            let config = RunnerDaemonConfig.loadFromEnvironment([
                "RUNNER_NETWORK_RETRY_ENABLED": trueWord
            ])
            XCTAssertTrue(config.networkRetryEnabled, "expected true for \(trueWord)")
        }
        for falseWord in ["0", "false", "False", "no", "NO", "off", "OFF"] {
            let config = RunnerDaemonConfig.loadFromEnvironment([
                "RUNNER_NETWORK_RETRY_ENABLED": falseWord
            ])
            XCTAssertFalse(config.networkRetryEnabled, "expected false for \(falseWord)")
        }
    }

    func testInvalidValuesFallBackToDefaults() {
        let config = RunnerDaemonConfig.loadFromEnvironment([
            "RUNNER_CAPABILITY_DISCOVERY_ENABLED":     "maybe",
            "RUNNER_NETWORK_RETRY_ENABLED":            "",
            "RUNNER_RETRY_BASE_DELAY_MS":              "not-a-number",
            "RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS":     "  ",
        ])
        XCTAssertEqual(config.capabilityDiscoveryEnabled,    RunnerDaemonConfig.defaults.capabilityDiscoveryEnabled)
        XCTAssertEqual(config.networkRetryEnabled,           RunnerDaemonConfig.defaults.networkRetryEnabled)
        XCTAssertEqual(config.retryBaseDelayMs,              RunnerDaemonConfig.defaults.retryBaseDelayMs)
        XCTAssertEqual(config.heartbeatRetryMaxAttempts,     RunnerDaemonConfig.defaults.heartbeatRetryMaxAttempts)
    }

    func testEmptyCacheDirTreatedAsAbsent() {
        let config = RunnerDaemonConfig.loadFromEnvironment([
            "RUNNER_TEST_SETUP_CACHE_DIR": "   "
        ])
        XCTAssertNil(config.testSetupCacheDir)
    }

    func testRetryPolicyFactoriesUseConfigValues() {
        let config = RunnerDaemonConfig(
            capabilityDiscoveryEnabled:   true,
            testSetupCacheDir:            nil,
            networkRetryEnabled:          true,
            retryBaseDelayMs:             500,
            retryMaxDelayMs:              45_000,
            heartbeatRetryMaxAttempts:    7,
            resultUploadRetryMaxAttempts: 11,
            downloadRetryMaxAttempts:     5
        )
        let heartbeat = RunnerRetryPolicy.heartbeat(config: config)
        XCTAssertEqual(heartbeat.maxAttempts,  7)
        XCTAssertEqual(heartbeat.baseDelayMs,  500)
        XCTAssertEqual(heartbeat.maxDelayMs,   45_000)

        let resultUpload = RunnerRetryPolicy.resultUpload(config: config)
        XCTAssertEqual(resultUpload.maxAttempts, 11)

        let download = RunnerRetryPolicy.download(config: config)
        XCTAssertEqual(download.maxAttempts, 5)

        let poll = RunnerRetryPolicy.poll(config: config)
        XCTAssertEqual(poll.maxAttempts, .max)
        XCTAssertEqual(poll.baseDelayMs, 500)
    }
}
