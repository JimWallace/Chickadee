// APIServer/Configuration/UWDatesConfig.swift
//
// Gate for the UWaterloo important-dates integration (the #278 decision:
// this feature is UW-only by design, kept as an optional institutional
// integration rather than generalized). The feed URL and event-relevance
// keywords in UWImportantDatesService stay UWaterloo-specific; deployments
// outside UWaterloo set UW_IMPORTANT_DATES_ENABLED=false, which leaves
// GET /api/v1/uw-dates unregistered so the assignment editors' due-date
// warning fetch silently no-ops.

struct UWDatesConfig: Sendable {
    /// Whether GET /api/v1/uw-dates is registered. Defaults to true — this is
    /// a UWaterloo-aligned codebase, so the UW deployment needs no env change.
    let enabled: Bool

    static let `default` = UWDatesConfig(enabled: true)

    static func fromEnvironment() -> Self {
        UWDatesConfig(enabled: environmentBool("UW_IMPORTANT_DATES_ENABLED") ?? true)
    }
}
