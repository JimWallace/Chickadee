// APIServer/Utilities/AuthoringChecks/AuthoringCheck.swift
//
// One rule-based check of an assignment's authoring content (#2747). A check
// reads an `AuthoringSnapshot` and returns findings. It reads nothing else and
// runs nothing, so each one is a pure function with its own unit test. The MCP
// tool `check_assignment` runs every check in `AuthoringCheckCatalog`.
//
// A check reports. It never refuses a save: refusals stay with the authoring
// doors (`ManifestCoherence`, `validateManifestDependencies`).

import Core

protocol AuthoringCheck: Sendable {
    /// The stable id that every finding of this check carries, as
    /// `<area>.<problem>`, for example `tiers.noPublicTest`.
    static var id: String { get }
    /// The severity of every finding of this check.
    static var severity: AuthoringFinding.Severity { get }

    /// The problems this check finds in `snapshot`. Empty when there are none.
    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding]
}

extension AuthoringCheck {
    /// A finding of this check, with its id and severity filled in.
    func finding(
        at location: AuthoringFinding.Location, _ message: String, fix: String? = nil
    ) -> AuthoringFinding {
        AuthoringFinding(
            checkID: Self.id, source: .check, severity: Self.severity,
            location: location, message: message, suggestedFix: fix)
    }
}
