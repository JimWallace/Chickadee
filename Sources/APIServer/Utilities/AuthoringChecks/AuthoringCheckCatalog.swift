// APIServer/Utilities/AuthoringChecks/AuthoringCheckCatalog.swift
//
// The authoring checks that `check_assignment` runs, in report order (#2747).
// A new check is one line here.

import Core

enum AuthoringCheckCatalog {
    static let all: [any AuthoringCheck] = [
        ManifestCoherenceCheck(),
        VariantFailureCheck(),
        UnresolvedPlaceholderCheck(),
        ExpressionErrorCheck(),
        NoPublicTestCheck(),
        StarterPassesCheck(),
        TimingMarginCheck(),
        MissingMetricCheck(),
        ZeroPointsCheck(),
    ]

    /// The ids of every check, in run order.
    static var ids: [String] { all.map { type(of: $0).id } }

    /// Every finding of every check, most severe first. Findings of the same
    /// severity keep the catalog order, then each check's own order.
    static func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        let found = all.flatMap { $0.findings(in: snapshot) }
        return found.enumerated()
            .sorted { lhs, rhs in
                lhs.element.severity.rank != rhs.element.severity.rank
                    ? lhs.element.severity.rank < rhs.element.severity.rank
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
