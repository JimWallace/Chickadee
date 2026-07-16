// APIServer/MCP/OAuth/MCPOAuthSurface.swift
//
// Resource-surface resolution for the OAuth flow: which MCP resource an
// authorization targets (content authoring vs admin diagnostics) and the
// per-surface parameters — issuer/audience, scope ceiling, signing authority,
// token TTL, and role gate.  Depended on by both the consent (authorize) and
// machine (token) paths.
//
// Split out of MCPOAuthRoutes.swift along its MARK seams (#1122, following the
// v0.4.37 large-source splits).  No logic change.

import Fluent
import Vapor

extension MCPOAuthRoutes {
    /// Which MCP resource an authorization targets.  The two surfaces have
    /// disjoint scope namespaces (`content:*` vs `diagnostics:*`), so every
    /// post-authorize step derives the surface from the stored scope — no
    /// resource column is needed on the consent/code/grant tables.
    enum Surface: Sendable {
        case content
        case admin
    }

    /// The per-surface parameters the OAuth flow varies: issuer/audience, the
    /// mode-clamped scope ceiling, the signing authority, token TTL, and the
    /// role a human must hold to authorize this resource.
    struct ResolvedSurface {
        let surface: Surface
        let issuer: String
        let audience: String
        let advertisedScopes: [String]
        let accessTokenTTLSeconds: Int
        let authority: MCPTokenAuthority?

        var scopeCeiling: Set<String> { Set(advertisedScopes) }

        /// The role gate: content authoring needs course staff (TA+ in any
        /// course, or admin); admin diagnostics needs admin. This only decides
        /// who may grant a scope at all — per-course authority is re-checked per
        /// tool call by `authorizeCourseAccess`, which is already
        /// enrollment-scoped, so this coarse gate never widens what an agent can
        /// actually touch (#417).
        func permits(_ user: APIUser, db: Database) async throws -> Bool {
            switch surface {
            case .content: return try await isStaffAnywhere(user, db: db)
            case .admin: return user.isAdmin
            }
        }

        var permittedRoleLabel: String {
            switch surface {
            case .content: return "instructors and admins"
            case .admin: return "admins"
            }
        }

        var purposeLabel: String {
            switch surface {
            case .content: return "author course content"
            case .admin: return "read server diagnostics"
            }
        }
    }

    /// Resolves the surface for a NEW authorize request: the RFC 8707 `resource`
    /// parameter wins when present; otherwise the requested scope's namespace
    /// decides.  Falls back to content when the admin surface isn't mounted.
    func resolveSurface(req: Request, resource: String?, scope: String?) -> ResolvedSurface {
        let cfg = req.application.appConfig
        let wantsAdmin: Bool
        if let resource, !resource.isEmpty {
            wantsAdmin = isAdminResource(resource, req: req)
        } else {
            wantsAdmin = Self.scopeStringTargetsAdmin(scope ?? "")
        }
        if wantsAdmin,
            let adminEndpoints = AdminMCPEndpoints.resolve(mcp: cfg.mcp, security: cfg.security)
        {
            // The admin surface rides on MCP_MODE, shares the content signing
            // authority (separation is by audience), and is always read-only —
            // it advertises only diagnostics:read even under MCP_MODE=read_write.
            return ResolvedSurface(
                surface: .admin,
                issuer: adminEndpoints.issuer,
                audience: adminEndpoints.resource,
                advertisedScopes: adminMCPAdvertisedScopes.map(\.rawValue),
                accessTokenTTLSeconds: cfg.mcp.accessTokenTTLSeconds,
                authority: req.application.mcpTokenAuthority)
        }
        return ResolvedSurface(
            surface: .content,
            issuer: endpoints.issuer,
            audience: endpoints.resource,
            advertisedScopes: cfg.mcp.mode.advertisedScopes.map(\.rawValue),
            accessTokenTTLSeconds: accessTokenTTLSeconds,
            authority: req.application.mcpTokenAuthority)
    }

    /// Resolves the surface for a STORED scope (the post-authorize steps, which
    /// have no `resource` parameter).  Reliable because the scope namespaces are
    /// disjoint and `resolveScopes` clamps a request to a single surface.
    func surfaceForScope(_ scope: String, req: Request) -> ResolvedSurface {
        resolveSurface(req: req, resource: nil, scope: scope)
    }

    private func isAdminResource(_ resource: String, req: Request) -> Bool {
        let cfg = req.application.appConfig
        guard let adminEndpoints = AdminMCPEndpoints.resolve(mcp: cfg.mcp, security: cfg.security)
        else { return false }
        return resource == adminEndpoints.resource
    }

    static func scopeStringTargetsAdmin(_ scope: String) -> Bool {
        let parts = Set(scope.split(separator: " ").map(String.init))
        return DiagnosticScope.allCases.contains { parts.contains($0.rawValue) }
    }
}
