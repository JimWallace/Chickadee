// Tests/APITests/Infrastructure/AppConfigLogSummaryBranchTests.swift
//
// The optional lines of `AppConfig.logSummary`. `AppConfigTests` checks that
// a local-mode summary redacts its secrets; this suite loads a config with
// every optional feature on (SSO, a public base URL, scan mode, BrightSpace,
// alerts, an outbound proxy, MCP, and the UW dates integration off) and checks
// that each one logs its line and that no secret value reaches the log. A
// second config checks the disabled idle timeout and the BrightSpace line
// that waits for the authorize flow.
//
// The variables are set through `withTestEnvironment`, which overrides the
// environment for this task only. No new environment variable is read.

import Foundation
import Logging
import Synchronization
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct AppConfigLogSummaryBranchTests {

    /// Every variable either test sets, cleared first so that the host
    /// environment cannot add or remove a line.
    private static let cleared: [String: String?] = [
        "PUBLIC_BASE_URL": nil, "ENFORCE_HTTPS": nil, "SESSION_IDLE_TIMEOUT_MINUTES": nil,
        "SESSION_IDLE_WARNING_SECONDS": nil, "OIDC_CLIENT_ID": nil, "OIDC_CLIENT_SECRET": nil,
        "RUNNER_SHARED_SECRET": nil, "SCAN_MODE": nil, "UW_IMPORTANT_DATES_ENABLED": nil,
        "BRIGHTSPACE_URL": nil, "BRIGHTSPACE_APP_ID": nil, "BRIGHTSPACE_APP_KEY": nil,
        "BRIGHTSPACE_USER_ID": nil, "BRIGHTSPACE_USER_KEY": nil, "BRIGHTSPACE_SYNC_DEBOUNCE_SECS": nil,
        "ALERT_ENABLED": nil, "ALERT_WEBHOOK_URL": nil, "OUTBOUND_HTTP_PROXY": nil, "MCP_MODE": nil,
        "ENABLE_NON_SSO_AUTH_MODES": nil,
    ]

    private static func environment(_ overrides: [String: String]) -> [String: String?] {
        var merged = cleared
        for (key, value) in overrides { merged[key] = value }
        return merged
    }

    private static func summary(of config: AppConfig) -> [String] {
        let sink = SummaryLineSink()
        var logger = Logger(label: "appconfig.summary.test")
        logger.handler = SummaryCaptureLogHandler { line in sink.append(line) }
        logger.logLevel = .trace
        config.logSummary(to: logger)
        return sink.lines
    }

    @Test func everyOptionalFeatureLogsItsLineWithoutItsSecrets() async throws {
        let lines = try await withTestEnvironment(
            Self.environment([
                "ENABLE_NON_SSO_AUTH_MODES": "true",
                "PUBLIC_BASE_URL": "https://chickadee.example",
                "SESSION_IDLE_TIMEOUT_MINUTES": "45",
                "SESSION_IDLE_WARNING_SECONDS": "0",
                "OIDC_CLIENT_ID": "client-id-value",
                "OIDC_CLIENT_SECRET": "oidc-secret-value",
                "RUNNER_SHARED_SECRET": "runner-secret-value",
                "SCAN_MODE": "true",
                "UW_IMPORTANT_DATES_ENABLED": "false",
                "BRIGHTSPACE_URL": "https://learn.example/",
                "BRIGHTSPACE_APP_ID": "bs-app-id-value",
                "BRIGHTSPACE_APP_KEY": "bs-app-key-value",
                "BRIGHTSPACE_USER_ID": "bs-user-id-value",
                "BRIGHTSPACE_USER_KEY": "bs-user-key-value",
                "ALERT_ENABLED": "true",
                "ALERT_WEBHOOK_URL": "https://hooks.example/secret-path",
                "OUTBOUND_HTTP_PROXY": "proxy.example:3128",
                "MCP_MODE": "read_only",
            ])
        ) {
            let config = try AppConfig.fromEnvironment(
                workDir: "/tmp/", authModeOverride: .dual, databaseOverride: .localTest)
            return Self.summary(of: config)
        }
        let blob = lines.joined(separator: "\n")

        #expect(blob.contains("auth=dual"))
        #expect(blob.contains("security: publicBaseURL=https://chickadee.example"))
        #expect(blob.contains("sessionIdleTimeoutMinutes=45, idleWarning=disabled"))
        #expect(blob.contains("oidc: clientID=[set], clientSecret=[set]"))
        #expect(blob.contains("workers: sharedSecret=[set]"))
        #expect(lines.contains { $0.hasPrefix("warning") && $0.contains("SCAN_MODE=true") })
        #expect(blob.contains("uwDates: disabled"))
        #expect(blob.contains("brightspace: baseURL=https://learn.example, appID=[set], appKey=[redacted]"))
        #expect(blob.contains("userID=[set], userKey=[redacted], debounceSecs=90.0"))
        #expect(blob.contains("alerts: enabled, checkInterval=60.0s"))
        #expect(blob.contains("webhook=[set]"))
        #expect(blob.contains("outboundProxy: proxy.example:3128"))
        #expect(blob.contains("mcp: mode=read_only"))
        #expect(blob.contains("adminMCP: /admin-mcp mounted"))

        for secret in [
            "client-id-value", "oidc-secret-value", "runner-secret-value", "bs-app-id-value", "bs-app-key-value",
            "bs-user-id-value", "bs-user-key-value", "secret-path",
        ] {
            #expect(!blob.contains(secret), "logSummary printed \(secret)")
        }
    }

    @Test func aDisabledIdleTimeoutAndAppOnlyBrightSpaceLogTheirOwnLines() async throws {
        let lines = try await withTestEnvironment(
            Self.environment([
                "SESSION_IDLE_TIMEOUT_MINUTES": "0",
                "BRIGHTSPACE_URL": "https://learn.example",
                "BRIGHTSPACE_APP_ID": "bs-app-id-value",
                "BRIGHTSPACE_APP_KEY": "bs-app-key-value",
                "BRIGHTSPACE_SYNC_DEBOUNCE_SECS": "30",
            ])
        ) {
            let config = try AppConfig.fromEnvironment(
                workDir: "/tmp/", authModeOverride: .local, databaseOverride: .localTest)
            #expect(config.brightspace == nil)
            #expect(config.brightspaceApp != nil)
            return Self.summary(of: config)
        }
        let blob = lines.joined(separator: "\n")

        #expect(blob.contains("security: sessionIdleTimeout=disabled"))
        #expect(blob.contains("userKey=(awaiting authorize), debounceSecs=30.0"))
        #expect(!blob.contains("bs-app-id-value"))
        #expect(!blob.contains("bs-app-key-value"))
        // Local mode, no public base URL and every feature off: none of the
        // optional lines appear.
        for absent in [
            "security: publicBaseURL", "oidc:", "SCAN_MODE", "uwDates:", "alerts:", "outboundProxy:", "mcp:",
        ] {
            #expect(!blob.contains(absent), "unexpected line: \(absent)")
        }
    }
}

private final class SummaryLineSink: Sendable {
    private let stored = Mutex<[String]>([])

    func append(_ line: String) {
        stored.withLock { $0.append(line) }
    }

    var lines: [String] {
        stored.withLock { $0 }
    }
}

private struct SummaryCaptureLogHandler: LogHandler {
    let onLog: @Sendable (String) -> Void

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        onLog("\(event.level) \(event.message)")
    }
}
