// APIServer/Utilities/AuthoringChecks/UnresolvedPlaceholderCheck.swift
//
// Reports each per-student input name that the content refers to but the
// manifest does not declare (#2747). `preview_personalization` audits one seed;
// this compares names, so it holds for every seed: an undeclared name resolves
// for none. A declared expression that fails to evaluate is
// `personalization.expressionError`, not this check.

import Core

struct UnresolvedPlaceholderCheck: AuthoringCheck {
    static let id = "placeholders.unresolved"
    static let severity = AuthoringFinding.Severity.error

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        let declared = PersonalizationPlaceholders.declared(in: snapshot.manifest)
        return snapshot.placeholderNames.subtracting(declared).sorted().map { name in
            finding(
                at: .input(name),
                "\(name) is used in the starter notebook or a pattern-family case, but no input declares it, "
                    + "so no student gets a value for it.",
                fix: "Declare \(name) as a global or section input, or remove the reference.")
        }
    }
}
