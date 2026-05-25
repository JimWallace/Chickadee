// APIServer/Configuration/MCPMode.swift
//
// Operating mode for the content-authoring MCP server, selected by `MCP_MODE`.
// Three states instead of a binary on/off so an operator can expose the
// endpoint for inspection without granting write access:
//
//   off         — not mounted at all (/mcp and /oauth/* 404, no token authority)
//   read_only   — mounted and authenticated, but `content:write` is never honored
//   read_write  — full content authoring (read + write)
//
// `read_only` is implemented as a server-wide ceiling on the OAuth scopes any
// request may exercise (`scopeCeiling`), enforced once in the bearer middleware.
// Because the ceiling is applied per request — not just at token-mint time — a
// `content:write` token issued while the server was `read_write` loses write the
// instant an operator flips to `read_only`, without any token revocation.

enum MCPMode: String, Sendable, CaseIterable {
    case off
    case readOnly = "read_only"
    case readWrite = "read_write"

    /// True for `read_only` and `read_write`: the `/mcp` transport, OAuth flow,
    /// discovery metadata, and token authority are all mounted.  `off` mounts
    /// nothing.
    var isMounted: Bool { self != .off }

    /// The maximum set of content scopes a request may exercise in this mode.
    /// The bearer middleware intersects each token's scopes with this set, so
    /// the rest of the stack (per-tool scope checks, `tools/list` filtering,
    /// resources) needs no mode awareness.
    var scopeCeiling: Set<ContentScope> {
        switch self {
        case .off: return []
        case .readOnly: return [.read]
        case .readWrite: return [.read, .write]
        }
    }

    /// Parses `MCP_MODE`.  Canonical values are `off`, `read_only`,
    /// `read_write`; a handful of obvious synonyms are accepted so an operator
    /// fat-fingering `readonly` or `on` still lands on the intended mode.
    /// Unset, empty, or unrecognized → `.off` (fail safe; the redacted startup
    /// summary logs the resolved mode so a typo is visible).
    static func parse(_ raw: String?) -> MCPMode {
        guard let raw else { return .off }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "off", "false", "0", "no", "disabled", "none", "":
            return .off
        case "read_only", "readonly", "read-only", "read", "ro":
            return .readOnly
        case "read_write", "readwrite", "read-write", "rw", "on", "true", "1", "yes", "enabled", "full":
            return .readWrite
        default:
            return .off
        }
    }
}
