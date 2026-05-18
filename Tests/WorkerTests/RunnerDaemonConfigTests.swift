import Testing

@testable import chickadee_runner

@Suite struct RunnerDaemonConfigTests {

    @Test func emptyEnvironmentUsesDefaults() {
        let config = RunnerDaemonConfig.loadFromEnvironment([:])
        #expect(config == .defaults)
    }

    @Test func validEnvVarsParsedAsExpected() {
        let env: [String: String] = [
            "RUNNER_CAPABILITY_DISCOVERY_ENABLED": "false",
            "RUNNER_TEST_SETUP_CACHE_DIR": "/var/cache/chickadee",
            "RUNNER_NETWORK_RETRY_ENABLED": "no",
            "RUNNER_RETRY_BASE_DELAY_MS": "250",
            "RUNNER_RETRY_MAX_DELAY_MS": "60000",
            "RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS": "9",
            "RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS": "12",
            "RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS": "3",
            "RUNNER_MIN_FREE_DISK_MB": "1024",
        ]
        let config = RunnerDaemonConfig.loadFromEnvironment(env)
        #expect(config.capabilityDiscoveryEnabled == false)
        #expect(config.testSetupCacheDir == "/var/cache/chickadee")
        #expect(config.networkRetryEnabled == false)
        #expect(config.retryBaseDelayMs == 250)
        #expect(config.retryMaxDelayMs == 60_000)
        #expect(config.heartbeatRetryMaxAttempts == 9)
        #expect(config.resultUploadRetryMaxAttempts == 12)
        #expect(config.downloadRetryMaxAttempts == 3)
        #expect(config.minFreeDiskMB == 1024)
    }

    @Test func minFreeDiskZeroDisablesPrecheck() {
        let config = RunnerDaemonConfig.loadFromEnvironment([
            "RUNNER_MIN_FREE_DISK_MB": "0"
        ])
        #expect(config.minFreeDiskMB == 0)
    }

    @Test func minFreeDiskInvalidFallsBackToDefault() {
        let config = RunnerDaemonConfig.loadFromEnvironment([
            "RUNNER_MIN_FREE_DISK_MB": "not-a-number"
        ])
        #expect(config.minFreeDiskMB == RunnerDaemonConfig.defaults.minFreeDiskMB)
    }

    @Test func boolAcceptsCommonAliases() {
        for trueWord in ["1", "true", "True", "TRUE", "yes", "YES", "on", "ON"] {
            let config = RunnerDaemonConfig.loadFromEnvironment([
                "RUNNER_NETWORK_RETRY_ENABLED": trueWord
            ])
            #expect(config.networkRetryEnabled, "expected true for \(trueWord)")
        }
        for falseWord in ["0", "false", "False", "no", "NO", "off", "OFF"] {
            let config = RunnerDaemonConfig.loadFromEnvironment([
                "RUNNER_NETWORK_RETRY_ENABLED": falseWord
            ])
            #expect(!config.networkRetryEnabled, "expected false for \(falseWord)")
        }
    }

    @Test func invalidValuesFallBackToDefaults() {
        let config = RunnerDaemonConfig.loadFromEnvironment([
            "RUNNER_CAPABILITY_DISCOVERY_ENABLED": "maybe",
            "RUNNER_NETWORK_RETRY_ENABLED": "",
            "RUNNER_RETRY_BASE_DELAY_MS": "not-a-number",
            "RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS": "  ",
        ])
        #expect(config.capabilityDiscoveryEnabled == RunnerDaemonConfig.defaults.capabilityDiscoveryEnabled)
        #expect(config.networkRetryEnabled == RunnerDaemonConfig.defaults.networkRetryEnabled)
        #expect(config.retryBaseDelayMs == RunnerDaemonConfig.defaults.retryBaseDelayMs)
        #expect(config.heartbeatRetryMaxAttempts == RunnerDaemonConfig.defaults.heartbeatRetryMaxAttempts)
    }

    @Test func emptyCacheDirTreatedAsAbsent() {
        let config = RunnerDaemonConfig.loadFromEnvironment([
            "RUNNER_TEST_SETUP_CACHE_DIR": "   "
        ])
        #expect(config.testSetupCacheDir == nil)
    }

    @Test func retryPolicyFactoriesUseConfigValues() {
        let config = RunnerDaemonConfig(
            capabilityDiscoveryEnabled: true,
            testSetupCacheDir: nil,
            networkRetryEnabled: true,
            retryBaseDelayMs: 500,
            retryMaxDelayMs: 45_000,
            heartbeatRetryMaxAttempts: 7,
            resultUploadRetryMaxAttempts: 11,
            downloadRetryMaxAttempts: 5,
            minFreeDiskMB: 128
        )
        let heartbeat = RunnerRetryPolicy.heartbeat(config: config)
        #expect(heartbeat.maxAttempts == 7)
        #expect(heartbeat.baseDelayMs == 500)
        #expect(heartbeat.maxDelayMs == 45_000)

        let resultUpload = RunnerRetryPolicy.resultUpload(config: config)
        #expect(resultUpload.maxAttempts == 11)

        let download = RunnerRetryPolicy.download(config: config)
        #expect(download.maxAttempts == 5)

        let poll = RunnerRetryPolicy.poll(config: config)
        #expect(poll.maxAttempts == .max)
        #expect(poll.baseDelayMs == 500)
    }
}
