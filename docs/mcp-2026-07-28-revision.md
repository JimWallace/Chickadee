# MCP 2026-07-28 specification revision — impact & adoption plan

**Status:** in progress. The spec published as final on 2026-07-28 (the dated
revision is live at `modelcontextprotocol.io/specification/2026-07-28`), and
the "do first" slice — RFC 9207 `iss` — has landed, together with the
guidance-delivery groundwork below. The version-adoption slice waits on the
connector SDK; tracked in
[#1218](https://github.com/jimwallace/chickadee/issues/1218). No production
change is required to keep working; see
[Backward compatibility](#backward-compatibility).

## TL;DR

- The 2026-07-28 revision is a **release candidate** (locked 2026-05-21) that
  publishes as final on **2026-07-28**, with a ~10-week SDK validation window.
  Nothing of ours changes behaviour on that date.
- It is a **breaking** spec versus 2025-11-25 (the revision we speak): it removes
  the `initialize`/`initialized` handshake and `Mcp-Session-Id`, moving protocol
  version + client info into a `_meta` object on every request, and adds a
  `server/discover` method. But the protocol is version-negotiated and updated
  clients are reported to fall back to the `initialize` handshake against
  2025-11-25 servers, so our server keeps serving traffic through the transition.
- **We are unusually well-positioned.** The revision's headline is
  statelessness, and our transport is already stateless. We already ship OAuth
  2.1 + PKCE, RFC 8707 resource indicators, and RFC 9728 metadata. We
  deliberately never built roots / sampling / logging — the three features this
  revision deprecates.
- **One concrete gap worth closing now:** RFC 9207 `iss` on the OAuth
  authorization response. Everything else is optional or forward-looking and is
  low-effort *because* we are already stateless.

## What the revision changes

Source of truth is the official announcement and spec (links under
[References](#references)). The material changes:

**Stateless core.**
- The `initialize`/`initialized` handshake is removed.
- The `Mcp-Session-Id` header is removed.
- Protocol version, client identity, and capabilities travel in a `_meta` object
  on every request instead of being exchanged once at connect time.
- A new `server/discover` method returns server capabilities on demand.
- Server-initiated interaction uses a multi-round-trip `InputRequiredResult`
  rather than long-lived SSE streams.

**Transport / infra.**
- New `Mcp-Method` and `Mcp-Name` headers let a load balancer route without
  parsing the body.
- Results may carry `ttlMs` / `cacheScope` client-caching hints.
- W3C Trace Context propagates through `_meta`.

**Authorization hardening (six SEPs).** Aligns the auth flow with OAuth 2.0 /
OpenID Connect. The ones with a server/AS obligation for us:
- **SEP-2468 — clients must validate the `iss` parameter on the authorization
  response per RFC 9207.** For an authorization server, the paired obligation is
  to *emit* `iss` on the authorization response and advertise it in metadata.
- SEP-837 (clients declare OIDC `application_type` at registration), SEP-2352
  (credentials bind to the issuer's `issuer`), SEP-2207 (refresh-token requests
  from OIDC servers) — primarily client-side.

**Extensions framework.** Namespaced, independently versioned extensions with
capability negotiation. Two official extensions launch: **MCP Apps** (sandboxed
HTML UIs) and **Tasks** (long-running work).

**Deprecations (annotation-only, ≥12-month window).** Roots, sampling, and
logging are deprecated but keep functioning for at least a year.

**Tool schemas.** Expand to full JSON Schema 2020-12 with composition
(`oneOf`/`anyOf`/`allOf`) and conditionals. Explicitly a "free upgrade at your
own pace" — nothing forces richer schemas.

## Backward compatibility

Two facts matter for "does anything break":

1. **It's an RC, not a flag day.** Final publishes 2026-07-28 with a ~10-week
   validation window for SDK maintainers. A running 2025-11-25 server does not
   change behaviour on the 28th, and our real client (the Claude connector)
   moves at SDK pace, not spec-publication pace.
2. **The protocol is version-negotiated.** A client that adds 2026-07-28 support
   still has to interoperate with the large installed base of 2025-11-25 servers
   during the transition. The field reporting (Microsoft, 4sysops, and the
   migration write-ups under [References](#references)) is that updated clients
   **fall back to the `initialize` handshake** for older servers. Treat this as
   *widely expected*, not a spec-level guarantee — the spec itself is breaking —
   but the practical outcome is that our server keeps serving traffic.

Our transport already advertises version negotiation: a supported requested
revision (`2025-11-25` or `2025-06-18`) is echoed back on `initialize`, an
unsupported one gets the latest we speak, and an unsupported
`MCP-Protocol-Version` transport header is rejected with HTTP 400
(`MCPRoutes.swift`, `MCPMethod.swift`).

## Where Chickadee already complies

The "mandatory before July 28" checklist in the migration guides targets
*stateful* servers. We satisfy nearly all of it already:

| Migration requirement | Chickadee today |
|---|---|
| Remove session-scoped state (the headline change) | Already stateless. `MCPRoutes.swift:12`: "transport stays stateless (no `Mcp-Session-Id` / `Last-Event-ID`)". Every POST is one JSON-RPC request authenticated per-request by an ES256 bearer JWT. No session store to remove. |
| Scale behind a round-robin LB, no sticky sessions | Follows from the above — nothing to re-architect or load-test. |
| OAuth 2.1 + PKCE | Full authorization server, Auth Code + PKCE (S256). |
| `.well-known` metadata / RFC 9728 protected-resource metadata | `MCPMetadataRoutes.swift`; `WWW-Authenticate` carries `resource_metadata`. |
| RFC 8707 resource indicators; `iss`/`aud` token validation | `MCPBearerAuthMiddleware.swift:35`; `MCPAccessTokenClaims.swift`. |
| Roots / sampling / logging deprecated | Non-event — v1 deliberately never implemented any of them. The deprecation vindicates the "tools + resources only" scoping. |

## The one gap worth closing now: RFC 9207 `iss`

We put `iss` in the access-token JWT and in discovery metadata, but **not** as a
query parameter on the OAuth authorization *response*, which is what RFC 9207
requires and SEP-2468 makes clients validate.

- `MCPOAuthRoutes+Authorize.swift:259-279` — the success/error redirect helpers
  append only `code`/`state` or `error`/`state`. No `iss`.
- `MCPMetadataRoutes.swift:46-61` — the RFC 8414 authorization-server metadata
  omits `authorization_response_iss_parameter_supported`.

**Fix (small, self-contained, good on its own merits):**
1. Append `iss` (the surface's issuer) to every `/oauth/authorize` redirect —
   both the success (`code`) and error responses — in
   `MCPOAuthRoutes+Authorize.swift`.
2. Advertise `authorization_response_iss_parameter_supported: true` in
   `authorizationServerMetadata` (`MCPMetadataRoutes.swift`).

This stands alone from the rest of the revision work; a strict updated client
could begin requiring it independently of the stateless changes.

**Shipped** (week of 2026-07-28): both halves — `iss` appended to every
authorize redirect, success and error alike, carrying the resolved surface's
issuer (so it always matches the minted token's `iss` claim, content or admin),
plus the `authorization_response_iss_parameter_supported: true` advertisement —
with assertions in the OAuth flow and metadata tests.

## Optional / forward-looking

Do these at our own pace, once the spec is final and SDKs ship — none is a
correctness blocker:

- **Add `"2026-07-28"` to `MCPProtocol.supportedVersions`** (`MCPMethod.swift:18`)
  and accept protocol version + client info via `_meta` on each request, making
  the `initialize` handshake optional (keep it for older clients). Additive
  plumbing, not a rewrite, precisely because we are already stateless.
- **Implement `server/discover`** (capabilities on demand) alongside the
  `_meta`-carried version.
- **`Mcp-Method` / `Mcp-Name` routing headers** — only useful for body-blind LB
  routing; we do not need it today.
- **Tool input schemas → JSON Schema 2020-12** — free upgrade; our schemas are
  simple, no forced change.
- **Tasks extension** — `validate_assignment` (our custom SSE-progress
  long-running call, `MCPRoutes.swift` `validationProgressStream`) is a natural
  fit for the official Tasks extension. Nice-to-have.
- **MCP Apps extension** — not relevant to this server.

## Plan for the week of 2026-07-28

1. Confirm the final spec text matches the RC (the RC noted the text could still
   shift), and that the SDK the Claude connector uses has shipped 2026-07-28
   support.
2. Land the RFC 9207 `iss` hardening (can go earlier — it does not depend on the
   revision). **Done** — see "The one gap worth closing now" above.
3. Add `"2026-07-28"` to the supported-version set + `_meta`-carried version +
   `server/discover`, keeping `initialize` as the fallback.
4. Verify the roots/sampling/logging deprecations are a no-op for us.
5. Evaluate the Tasks extension for `validate_assignment` and JSON Schema
   2020-12 for the tool catalog as separate follow-ups.

## Authoring-guidance delivery across the transition

The default authoring-voice guide and each course's own guide
(`courses.mcp_instructions` — the instructor MCP tab seeds one editable box
with the default, and a course that edits it replaces the default for its own
content) reach agents through one composition point —
`MCPServerInstructions.text(withCourseGuidance:)` — so the delivery surface can
move without the content forking:

- **2025-11-25 clients (today):** embedded in `initialize.instructions`,
  frozen per connection.
- **Now, spec-stable:** also exposed as live MCP resources —
  `chickadee://docs/authoring-voice` (the constant the instructions embed) and
  `chickadee://course/<code>/authoring-guidance` (scoped by the same
  `mcpCourseGuidance` resolver as the initialize embedding). Resources are
  untouched by the stateless revision, re-readable mid-session, and
  course-addressable, so guidance edits reach agents without a reconnect.
- **When `server/discover` is adopted here:** serve the same composed text from
  the discover handler (on-demand, so the reconnect caveat disappears
  entirely). Confirm where the final schema carries server instructions when
  doing that slice.
- **Watch:** the official "Skills over MCP" extension (structured instructions
  discovered and consumed through MCP) is the natural long-term convergence
  point for this kind of guidance; evaluate once the connector supports it.

## References

- MCP 2026-07-28 RC — official announcement:
  https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- Beta SDKs for the 2026-07-28 RC — official:
  https://blog.modelcontextprotocol.io/posts/sdk-betas-2026-07-28/
- MCP goes stateless — Microsoft Community Hub:
  https://techcommunity.microsoft.com/blog/appsonazureblog/mcp-just-went-stateless-%E2%80%94-what-the-2026-spec-changes-about-scaling-on-app-servic/4530222
- Stateless, routable headers, authorization hardening — 4sysops:
  https://4sysops.com/archives/2026-07-28-model-context-protocol-mcp-stateless-multi-round-trip-routable-headers-authorization-hardening/
- Agent authentication changes — WorkOS:
  https://workos.com/blog/mcp-2026-spec-agent-authentication
- Stateless migration guide — digitalapplied:
  https://www.digitalapplied.com/blog/mcp-2026-07-28-spec-stateless-migration-guide
