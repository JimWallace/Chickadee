import Fluent
import Vapor

/// Client-side diagnostic record posted from the student submit page when
/// the in-browser editor (JupyterLite + Pyodide) cannot start.
///
/// Two kinds:
///   - "preflight_fail"   — capability check failed before the iframe was
///                           mounted (e.g. service workers blocked)
///   - "watchdog_timeout" — the iframe mounted but the JupyterLite kernel
///                           did not become ready within the watchdog window
final class APIClientDiagnostic: Model, Content, @unchecked Sendable {
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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        userID: UUID,
        testSetupID: String?,
        kind: String,
        failedChecks: String?,
        userAgent: String?
    ) {
        self.userID = userID
        self.testSetupID = testSetupID
        self.kind = kind
        self.failedChecks = failedChecks
        self.userAgent = userAgent
    }
}
