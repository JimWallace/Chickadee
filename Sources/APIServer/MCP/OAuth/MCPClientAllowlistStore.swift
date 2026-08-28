// APIServer/MCP/OAuth/MCPClientAllowlistStore.swift
//
// Operator-managed allowlist of the OAuth client identities that may be
// authorized against this deployment's MCP surfaces.
//
// Why this exists: `/oauth/register` is open (Dynamic Client Registration), and
// a registration is inert until a UW-authenticated instructor consents at
// `/oauth/authorize`.  That gate is real but human — it depends on the
// instructor knowing which AI tools the University has approved for the data
// class in play.  This store turns it into a deployment policy the operator
// sets and the server enforces, which is a claim an assessor can verify.
//
// The key is the **redirect-URI origin**, not `client_id` (DCR-generated, so it
// cannot be configured ahead of time) and not `client_name` (self-asserted in
// the registration request — anything may claim to be a well-known product).
// The redirect URI is the one field that is both stable per client product and
// already validated on every authorization request.

import Foundation
import Vapor

/// The live set of client origins permitted to be authorized on this
/// deployment, seeded at startup from `<workDir>/.mcp-client-allowlist`.
///
/// An **empty** set means "allow any", which keeps development and the test
/// corpus working unchanged.  The fail-closed half of the policy lives at
/// mount time instead: production refuses to mount the MCP transports with an
/// empty allowlist (`mcpClientAllowlistRefusal`).
actor MCPClientAllowlistStore {
    private var allowed: Set<String>

    init(initialOrigins: Set<String> = []) {
        self.allowed = initialOrigins
    }

    /// The permitted origins, normalized. Empty means "allow any" (see above).
    func origins() -> Set<String> {
        allowed
    }

    func setOrigins(_ newValue: Set<String>) {
        allowed = newValue
    }

    /// True when a client whose registered redirect URI is `redirectURI` may be
    /// authorized here.
    ///
    /// Call this only with a redirect URI already validated against the
    /// client's registration, so the origin tested is one the client actually
    /// owns.  A redirect URI whose origin cannot be normalized (a scheme with
    /// no host, or plaintext `http` to somewhere that is not loopback) is
    /// refused whenever the allowlist is in force — it can never equal an entry
    /// that went through the same normalization.
    func permits(redirectURI: String) -> Bool {
        guard !allowed.isEmpty else { return true }
        guard let origin = MCPClientOrigin.normalized(redirectURI) else { return false }
        return allowed.contains(origin)
    }
}

/// Normalization for both halves of the comparison: the operator's allowlist
/// entries and the redirect URI presented at `/oauth/authorize` go through this
/// same function, so an entry can never be written in a form the check cannot
/// match.
enum MCPClientOrigin {
    /// Hosts for which plaintext `http` stays permitted, so local development
    /// against a locally-run agent keeps working.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// Reduces a URL to `scheme://host[:port]` — the origin — or nil when the
    /// input is not a usable client identity.
    ///
    /// Scheme and host are lowercased (both are case-insensitive per RFC 3986,
    /// and an operator will not write them consistently).  The path is dropped:
    /// one product varies its callback path across versions and platforms while
    /// its origin stays put.  A port is kept only when it is not the scheme's
    /// default, so `https://example.org` and `https://example.org:443` are the
    /// same entry.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard
            !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let rawScheme = components.scheme,
            let rawHost = components.host,
            !rawHost.isEmpty
        else { return nil }

        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        // A client identity is an HTTPS origin. Plaintext http is accepted only
        // for loopback, where there is no network to eavesdrop on.
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else {
            return nil
        }
        guard let port = components.port, port != defaultPort(for: scheme) else {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Result of reading the allowlist file: the usable origins plus whatever could
/// not be parsed, so startup can name a typo instead of silently dropping it.
struct MCPClientAllowlistFile: Sendable {
    let origins: Set<String>
    let invalidEntries: [String]

    static let empty = MCPClientAllowlistFile(origins: [], invalidEntries: [])
}

/// Reads `<workDir>/.mcp-client-allowlist`, following the established
/// file-backed store pattern (`.worker-secret`, `.local-runner-autostart`)
/// rather than adding an environment variable.
///
/// An absent or unreadable file is an empty allowlist, same as an empty one.
func readMCPClientAllowlistFromDisk(filePath: String) -> MCPClientAllowlistFile {
    guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
        let text = String(data: data, encoding: .utf8)
    else { return .empty }
    return parseMCPClientAllowlist(text)
}

/// One origin per line. Blank lines and `#`-prefixed comment lines are ignored;
/// everything else must normalize to an origin or it is reported as invalid.
func parseMCPClientAllowlist(_ text: String) -> MCPClientAllowlistFile {
    var origins: Set<String> = []
    var invalid: [String] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        if let origin = MCPClientOrigin.normalized(line) {
            origins.insert(origin)
        } else {
            invalid.append(line)
        }
    }
    return MCPClientAllowlistFile(origins: origins, invalidEntries: invalid)
}
