// APIServer/Configuration/AdminMCPMode.swift
//
// Operating mode for the admin diagnostic MCP server, selected by
// `ADMIN_MCP_MODE`.  Only two states — there is no `read_write`, because the
// admin surface is read-only by design (diagnosis, never mutation):
//
//   off        — not mounted at all (/admin/mcp 404, no token authority)
//   read_only  — mounted and authenticated; only `diagnostics:read` is honored
//
// Parallel to `MCPMode` (the content surface) but deliberately a separate type:
// the two surfaces have different scopes, audiences, and role gates, and must
// not share an enforcement path (docs/admin-mcp.md §2).

enum AdminMCPMode: String, Sendable, CaseIterable {
    case off
    case readOnly = "read_only"

    /// True for `read_only`: the `/admin/mcp` transport, discovery metadata, and
    /// token authority are mounted.  `off` mounts nothing.
    var isMounted: Bool { self != .off }

    /// The scopes this mode advertises and grants, in stable order.  Single
    /// source of truth for the discovery document, DCR, and the consent screen.
    var advertisedScopes: [DiagnosticScope] {
        switch self {
        case .off: return []
        case .readOnly: return [.read]
        }
    }

    /// Set form of `advertisedScopes`, used for membership/intersection checks
    /// by the bearer middleware.
    var scopeCeiling: Set<DiagnosticScope> { Set(advertisedScopes) }

    /// Parses `ADMIN_MCP_MODE`.  Canonical values are `off` and `read_only`; a
    /// few obvious synonyms are accepted.  Unset, empty, or unrecognized → `.off`
    /// (fail safe).  Note: unlike the content surface there is no `read_write`,
    /// so write-shaped values (`on`, `true`, `rw`) still resolve to `read_only` —
    /// the most this surface can ever be.
    static func parse(_ raw: String?) -> AdminMCPMode {
        guard let raw else { return .off }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "off", "false", "0", "no", "disabled", "none", "":
            return .off
        case "read_only", "readonly", "read-only", "read", "ro",
            "on", "true", "1", "yes", "enabled":
            return .readOnly
        default:
            return .off
        }
    }
}
