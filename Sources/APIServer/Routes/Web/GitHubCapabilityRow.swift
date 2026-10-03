// APIServer/Routes/Web/GitHubCapabilityRow.swift

/// One of the GitHub App's three options and whether GitHub grants it, as the
/// admin and course GitHub pages show it (#1776).
struct GitHubCapabilityRow: Encodable, Equatable {
    let label: String
    let granted: Bool

    /// One row per option, in display order.
    static func rows(for grants: GitHubAppGrants) -> [GitHubCapabilityRow] {
        GitHubAppGrants.Capability.allCases.map { GitHubCapabilityRow(label: $0.label, granted: grants.allows($0)) }
    }
}
