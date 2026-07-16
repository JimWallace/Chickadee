import Fluent
import Vapor

/// Client-side diagnostic record posted from the student submit page when
/// the in-browser editor (JupyterLite + Pyodide) cannot start — or hits an
/// uncaught JavaScript error.
///
/// Three kinds:
///   - "preflight_fail"   — capability check failed before the iframe was
///                           mounted (e.g. service workers blocked)
///   - "watchdog_timeout" — the iframe mounted but the JupyterLite kernel
///                           did not become ready within the watchdog window
///   - "editor_error"     — an uncaught error / unhandled promise rejection
///                           on the editor page (captured via window.onerror
///                           / unhandledrejection), carrying message + stack
///
/// `message` / `stack` / `source` are populated for "editor_error" and, where
/// available, for the kernel-unhealthy "watchdog_timeout" subtype. They carry
/// JupyterLite/Pyodide *infrastructure* error text only — the capture sites are
/// the editor-load path, never student-code execution — so no student-authored
/// content lands here.
final class APIClientDiagnostic: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "client_diagnostics"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @OptionalField(key: "test_setup_id")
    var testSetupID: String?

    @Field(key: "kind")
    var kind: String

    @OptionalField(key: "failed_checks")
    var failedChecks: String?

    @OptionalField(key: "user_agent")
    var userAgent: String?

    /// Error message for "editor_error" / kernel-unhealthy records (trimmed).
    @OptionalField(key: "message")
    var message: String?

    /// Stack trace for "editor_error" records (trimmed).
    @OptionalField(key: "stack")
    var stack: String?

    /// Where the error originated, for triage: "onerror", "unhandledrejection",
    /// or "kernel". nil for preflight/plain watchdog records.
    @OptionalField(key: "source")
    var source: String?

    /// ChickadeeVersion of the page build that emitted this report (from the
    /// `app-version` meta tag the page carries). Lets a diagnostic be attributed
    /// to a build: an OLD value means a stale browser tab still running
    /// pre-deploy code — and serving its cached editor bundle/wheel — so a
    /// recurring failure on an old appVersion is a stale-cache symptom, not a
    /// live regression. nil for clients that predate this field.
    @OptionalField(key: "app_version")
    var appVersion: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        userID: UUID,
        testSetupID: String?,
        kind: String,
        failedChecks: String?,
        userAgent: String?,
        message: String? = nil,
        stack: String? = nil,
        source: String? = nil,
        appVersion: String? = nil
    ) {
        self.userID = userID
        self.testSetupID = testSetupID
        self.kind = kind
        self.failedChecks = failedChecks
        self.userAgent = userAgent
        self.message = message
        self.stack = stack
        self.source = source
        self.appVersion = appVersion
    }
}
