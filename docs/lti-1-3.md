# LTI 1.3 support

**Status:** design note. Slice 1 is implemented. Nothing in this document
changes existing behaviour until slice 2 mounts a launch route.

This note tells how Chickadee can become an LTI 1.3 tool, so that a learning
management system (LMS) such as D2L Brightspace (UW LEARN) can launch it, link
its assignments, receive its grades, and share its roster. It also tells which
existing features stay as they are. The goal is **additive** support: a
deployment that registers no LTI platform behaves exactly as it does today.

## Terms

| Term | Meaning here |
|---|---|
| Platform | The LMS (for example, D2L at `learn.uwaterloo.ca`). |
| Tool | Chickadee. |
| Registration | One (issuer, client ID) pair that a platform administrator creates for the tool. |
| Deployment | One installation of a registration inside the platform. One registration can have many deployments. |
| Launch | A signed OIDC `id_token` that the platform sends to the tool when a user opens a link. |
| Context | The LMS course that a launch comes from (`context.id`). |
| Resource link | One placement of the tool inside a context (`resource_link.id`). |

## The four parts of LTI 1.3

| Part | What it does | What it replaces or adds in Chickadee |
|---|---|---|
| Core launch | The platform sends a signed `id_token` that identifies the user, the context and the role. | A second way to sign in. Local and DUO sign-in stay. |
| Deep Linking 2.0 | An instructor selects a Chickadee assignment from inside the LMS. The tool returns a signed link. | Pasting a vanity URL into LEARN by hand. |
| Assignment and Grade Services (AGS) 2.0 | The tool writes scores to LMS line items. | An alternative transport for the Valence grade push. |
| Names and Role Provisioning Services (NRPS) 2.0 | The tool reads the context membership. | An alternative source for the Valence classlist. |

## Compatibility rules

These rules keep every existing feature working. Each slice must obey them.

1. **No platform, no change.** When the `lti_platforms` table is empty, no LTI
   route accepts a request, and no page, header, cookie or sweep changes.
2. **No new environment variables.** The standing rule in `CLAUDE.md` applies.
   Platform registrations live in the database and an admin edits them in the
   UI. The tool key path derives from the working directory, the same way
   `.worker-secret` does.
3. **Valence stays.** The BrightSpace grade sync (`BrightSpaceGradeSyncService`)
   and the roster reconciler continue to work. A course uses AGS only when an
   instructor selects it for that course. Both transports can not write the same
   course at the same time.
4. **Sign-in stays.** `.local`, `.sso` and `.dual` modes do not change. An LTI
   launch is an extra door. It creates the same session type that the other doors
   create.
5. **Security headers stay.** The launch opens Chickadee in a new window. The
   `frame-ancestors 'self'` policy and cross-origin isolation do not change. See
   "Why a new window" below.
6. **Additive schema only.** New tables and nullable columns. No existing column
   changes meaning.

## Why a new window

Chickadee sends `frame-ancestors 'self'` and `X-Frame-Options: SAMEORIGIN`
(`SecurityHeadersMiddleware`). The LMS can thus not show Chickadee in an
iframe. It is easy to relax this for each registered platform. The real problem
is cross-origin isolation.

The notebook page must be cross-origin isolated (`COEPMiddleware`) for the
in-browser kernels and for browser grading. An isolated document inside an
iframe stays isolated only when the parent document is also isolated and the
iframe delegates `cross-origin-isolated`. The D2L page is not isolated. Inside a
D2L iframe, `ensureReady` would fail, and each submission would fall over to the
native worker. The marks would be correct but slow, and nothing would report the
failure. This is the #1274 failure mode.

D2L supports "open as external resource" (a new window) for an LTI link. Use it.
Iframe support is out of scope. If it is necessary later, it must start with a
measurement of the isolation result inside the platform iframe.

## Tool identity (slice 1)

### The tool key

The IMS Security Framework requires RS256 for the tool key. D2L does not accept
ES256. So the MCP key (`MCPTokenAuthority`, ES256) is not reused. A separate
actor, `LTIToolKeyAuthority`, holds an RSA 2048-bit key:

- The key file is `.lti-tool-key` in the working directory, mode 0600.
  `Application.ltiToolKeyFilePath` can override the path (tests use this).
- The key is created on **first use**, not at startup. A deployment that never
  uses LTI never writes the file, and test apps do not pay for RSA key
  generation.
- The key ID is derived from the public key (RFC 7638 thumbprint). A rotated key
  thus gets a new `kid` automatically.

### The JWKS endpoint

`GET /lti/jwks` returns the public key as a JSON Web Key Set. It needs no
authentication. It returns an empty key set while no platform is registered, so
it creates no key file on a deployment that does not use LTI.

### Platform registration

The `lti_platforms` table holds one row per registration:

| Column | Meaning |
|---|---|
| `issuer` | The platform `iss` value. |
| `client_id` | The client ID that the platform issued to the tool. |
| `deployment_ids` | The deployment IDs that the tool accepts, newline-delimited (the `MCPOAuthClient.redirectURIs` pattern). |
| `auth_login_url` | The platform OIDC authorization endpoint. |
| `access_token_url` | The platform OAuth2 token endpoint (AGS and NRPS). |
| `jwks_url` | The platform key set URL. |
| `display_name` | A label for the admin UI. |
| `enabled` | False stops all launches from this registration. |

`(issuer, client_id)` is unique. A launch from an issuer with no enabled row is
refused.

### Launch validation

`LTILaunchValidator` is a pure function. It takes the decoded claims, the
registered platform and the current time. It returns the validated launch, or a
typed `LTILaunchError`. It checks:

| Check | Rule |
|---|---|
| Issuer | `iss` equals the registered issuer. |
| Audience | `aud` contains the client ID. |
| Authorized party | When `aud` has more than one value, `azp` is present and equals the client ID. |
| Deployment | `deployment_id` is in the registered list. |
| Version | `version` is `1.3.0`. |
| Message type | `LtiResourceLinkRequest` or `LtiDeepLinkingRequest`. |
| Nonce | Present and not empty. (Single use is enforced in slice 2, in the database.) |
| Subject | `sub` is present and not empty. Anonymous launches are refused. |
| Time | `exp` is in the future and `iat` is not in the future, with 60 seconds of clock skew. |
| Context | A resource-link launch has a `context.id`. |

The signature check comes before this function. It uses the platform key set.

### Role mapping

`LTIRoleMapping` (Core) maps the `roles` claim to a `CourseRole`:

| LTI context role | `CourseRole` |
|---|---|
| `Instructor`, `Administrator`, `ContentDeveloper` | `instructor` |
| `Instructor#TeachingAssistant`, `Instructor#Grader`, `TeachingAssistant` | `ta` |
| `Learner` (and its sub-roles) | `student` |
| `Mentor`, institution roles, system roles, unknown values | no role; the launch is refused |

The mapping accepts the full URI forms and the simple context-role names
(`Instructor`) that LTI 1.3 still permits.

A teaching-assistant sub-role wins over the `Instructor` principal role. The
specification sends both for a TA, so "highest role wins" alone would make each
TA an instructor. Otherwise the highest mapped role wins. A launch never grants the deployment-level
`admin` role. Institution and system roles are not used to grant a course role,
because they describe the user, not the user in this course.

## Launch (slice 2)

**Status:** implemented. `LTIRoutes+Launch.swift`, `LTIIdentityResolver`,
`LTICourseBinding`, `LTIBindRoutes`.

Two routes, both public and outside the CSRF group:

1. `GET|POST /lti/login` — third-party initiated login. The tool finds the one
   enabled registration for `iss` (and `client_id` when sent), stores the hash
   of a new `state` and a new `nonce` in `lti_login_states` (five minutes),
   sets the `state` in a cookie, and redirects to the platform
   `auth_login_url` with `response_mode=form_post`.
2. `POST /lti/launch` — the platform posts the `id_token` and `state`. The tool:
   1. requires the state cookie to equal the posted `state`;
   2. consumes the `state` row in one atomic
      `UPDATE … WHERE consumed = false RETURNING` (the MCP OAuth code
      primitive, `burnConsumable`), then refuses an expired row;
   3. verifies the signature against the platform key set
      (`LTIPlatformKeyCache`), and fetches the key set again once when a token
      does not verify, at most every 30 seconds;
   4. runs `LTILaunchValidator`, and checks the `nonce` against the stored one;
   5. finds or creates the user (below), and creates a normal session, with a
      new session ID, exactly as local and SSO sign-in do;
   6. sends the user to the bound course (below).

The state lives in the database and in a cookie. The database row makes it
single use. The cookie binds the launch to the browser that started the login,
so an attacker cannot hand a victim a launch that the attacker completed (login
CSRF). The cookie is `SameSite=None; Secure` over HTTPS, because the launch is
a cross-site POST, and it is set on `/lti` only. A browser that blocks it, for
example inside an LMS iframe, gets a page that says to open the link in a new
window.

Every refusal is an `LTILaunchFailure`: an `AbortError` that the existing error
page shows as one sentence. The server log names the rule that failed and never
the token.

### Identity

Links live in their own table, `lti_identities` (platform, subject → account),
unique per (platform, subject). An account keeps its `authProvider`, so one
person can sign in with DUO and also launch from the LMS. In order:

1. A known (platform, subject) resolves to its account.
2. When the platform is trusted for usernames (the per-platform "Trust this
   platform's username" switch, off by default) and the launch carries a
   `username` custom parameter (D2L: `username=$User.username`), the launch
   links to the account with that username. If there is none, it creates one
   shaped like a pre-SSO stub (`duo-oidc`, no subject), so a later DUO sign-in
   adopts the same account.
3. Otherwise the subject gets its own account, `lti-` plus 16 hex digits of
   SHA-256(platform|subject): stable, and opaque.

A launch never links to an admin or MCP account, and never gives one account a
second subject on one platform. Either would let an LMS user take over an
account that the LMS does not own. A `username` value that still starts with
`$` (the platform did not substitute the variable) counts as absent.

### Courses

A context binds to one `APICourse` through two nullable columns,
`lti_platform_id` and `lti_context_id`. An unbound context binds itself to the
one unarchived course whose `brightspaceOrgUnitID` equals `context.id`, because
D2L sends the org unit ID as `context.id` and the LEARN tab already made that
link. Otherwise:

- an instructor launch goes to `/lti/bind`, which lists the unarchived, unbound
  courses the instructor teaches, and binds the chosen one (audited as
  `lti.course_bound`);
- any other launch shows "This LMS course is not linked to a Chickadee course
  yet" (403).

### Enrollment

A launch into a bound course enrolls a user who is not enrolled yet, at the
role that the launch claims. The platform is admin-registered and is the
authority for its own roster, so no per-course switch gates this. A launch
never changes an existing enrollment: a TA made an instructor in Chickadee stays
one, and a student does not become a TA because the LMS says so later.

## Deep Linking (slice 3)

**Status:** implemented. `LTIDeepLinkRoutes`, `LTIDeepLinkingResponse`,
`LTIPendingDeepLink`.

1. The launch checks an `LtiDeepLinkingRequest` before anyone is signed in:
   the `deep_linking_settings` claim must accept `ltiResourceLink` and give an
   `https` return URL, the launch must name a context, and the role must be TA
   or instructor. A student gets 403; anything else gets 400.
2. The verified request (return URL, `data`, deployment, `accept_multiple`) is
   held in the session. The return URL comes only from the signed token, never
   from the browser, so the picker cannot be pointed at another site. Every
   launch first clears an older, unanswered request.
3. `/lti/deep-link` lists the bound course's assignments, as checkboxes or, when
   the platform accepts one item, radios. An unbound context goes through
   `/lti/bind` first and then continues to the picker.
4. The choice becomes an `LtiDeepLinkingResponse` signed with the tool key:
   `iss` = the client ID, `aud` = the platform issuer, the request's `data`
   echoed, and one `ltiResourceLink` per assignment with the launch URL and
   `custom.assignment` = the assignment public ID. It is audited as
   `lti.content_linked`.
5. The return page posts the JWT to the return URL. Its CSP `form-action`
   allows exactly that origin for that one response. There is no auto-submit:
   the CSP forbids inline script, so the page has one button.

A resource-link launch that carries `custom.assignment` opens that assignment,
when it is in the bound course, at its vanity URL; otherwise it opens the
course dashboard.

A `lineItem` is not sent yet; it comes with AGS in slice 4.

## Grades through AGS (slice 4)

The existing grade-sync machinery stays: the pending flag, the debounce, the
sweep, the retry rules and the audit log. Only the final "send one score" step
gets a second implementation:

1. Get an access token with the client-credentials grant and a JWT assertion
   signed by the tool key (`scope` = the AGS scopes).
2. Find or create the line item for the assignment (`resourceId` = assignment
   public ID).
3. Post a score with `scoreGiven`, `scoreMaximum`, `activityProgress` and
   `gradingProgress`.

A course selects its transport: Valence (the default, today's behaviour) or
AGS. The two are never active for the same course.

AGS removes the per-instructor Valence key problem that
[brightspace-setup.md](brightspace-setup.md) describes. The write permission
comes with the tool registration, not with a user key.

## Roster through NRPS (slice 5)

The roster reconciler (`LearnRosterReconciler`) gets a second source: the NRPS
membership service URL from the launch. It reduces the membership into the same
`BrightSpaceIdentityIndex` shape so that one set of matching rules applies.

## Compliance

LTI brings names, email addresses and student numbers from a new source.
Before a production registration:

- add the launch claims, NRPS and AGS to
  [compliance/data-flow-inventory.md](compliance/data-flow-inventory.md);
- add the LMS as a counterparty in
  [compliance/trust-boundary.md](compliance/trust-boundary.md);
- request the UW Information Risk Assessment through the Learning Environment
  team.

## Slice plan

| Slice | Content | Behaviour change for a deployment with no platform |
|---|---|---|
| 1 | `LTIToolKeyAuthority`, `GET /lti/jwks`, `lti_platforms` table and model, `LTILaunchValidator`, `LTIRoleMapping` | None. The JWKS is empty. |
| 1b (done) | Admin UI to register a platform, and the tool configuration values to give to the LMS administrator | None. A new admin tab. |
| 2 (done) | `/lti/login`, `/lti/launch`, state table, identity, course binding | None. Both routes refuse an unknown issuer. |
| 3 (done) | Deep Linking | None. |
| 4 | AGS transport | None. Valence stays the default. |
| 5 | NRPS roster source | None. |

Each slice has Swift Testing coverage. The launch tests use a test platform that
signs `id_token` values with a key that the test controls, and each validation
rule has a negative test.
