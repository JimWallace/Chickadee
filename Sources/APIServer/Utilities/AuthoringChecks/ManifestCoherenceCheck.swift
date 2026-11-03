// APIServer/Utilities/AuthoringChecks/ManifestCoherenceCheck.swift
//
// Reports each `ManifestCoherence` rule that the stored manifest breaks
// (#2747). Every authoring door refuses an edit that introduces a violation,
// but an edit may keep one that the manifest already had, so a legacy manifest
// can still carry one. This check is how an author finds it.

import Core

struct ManifestCoherenceCheck: AuthoringCheck {
    static let id = "manifest.incoherent"
    static let severity = AuthoringFinding.Severity.error

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        ManifestCoherence.violations(in: snapshot.manifest).map { finding(at: .assignment, $0) }
    }
}
