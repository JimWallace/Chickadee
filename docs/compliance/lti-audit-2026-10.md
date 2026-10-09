# LTI 1.3 — Security and Privacy Audit (2026-10)

Prepared for the UW Information Risk Assessment (IRA). This audit applies the
seven control areas of the Phase-1 audit
([`ira-audit-report.md`](ira-audit-report.md)) to the LTI 1.3 tool
([`docs/lti-1-3.md`](../lti-1-3.md)). The Phase-1 audit and its 2026-07
successor cover the MCP surfaces only. LTI was built after both.

- Repository: `JimWallace/Chickadee`, snapshot `VERSION` **0.5.602**
- Scope: `Sources/APIServer/LTI/`, the `APILTI*` models and their migrations,
  the LTI routes in `Routes/Web/AdminRoutes+LTI.swift` and
  `Routes/Web/InstructorLMSRoutes+LTI*.swift`, and the parts of the security
  headers, session and sign-in code that a launch uses.
- Method: every file in scope was read. The per-flow data inventory is in
  [`data-flow-inventory.md`](data-flow-inventory.md) §"LTI 1.3 flows". The
  counterparty note is in [`trust-boundary.md`](trust-boundary.md) §"The LMS as
  a counterparty". This audit does not repeat them.
- Status: **read-only audit.** No code was changed. The findings below are
  open.

Paths below are relative to `Sources/APIServer/` unless they say otherwise.

---

## Executive summary

The core of the LTI implementation is sound. The launch validation checks the
signature against the platform's key set, the issuer, the audience, `azp`,
expiry, the deployment, the version, the message type and the nonce. The
`state` value is single-use through an atomic `UPDATE`, and only its SHA-256 is
stored. A launch rotates the session ID, as the other sign-in doors do. No LTI
secret is stored: a registration holds only public URLs and identifiers, and
the tool key is a local file with mode 0600. No LTI table is reachable from
either MCP surface. The grade-sync failure text holds no grade, no LMS subject
and no LMS response body, so the BrightSpace F-2 pattern does not occur.

**The residual risk is trust in values that the platform supplies.** The
material findings all have one shape: Chickadee accepts a URL, an identity link
or a course binding from a platform, and does not limit it to what that
platform owns. Each one needs a registered platform that is compromised,
misconfigured, or one of several. None is reachable by a student or an
instructor on their own.

| # | Control area | Status |
|---|--------------|--------|
| 1 | Bounded capability surface | **Pass** |
| 2 | Data flow and egress (minimisation) | **Gap** (L-1: service URLs are not bound to the platform host) |
| 3 | Identity and account boundary | **Gap** (L-2: the admin refusal holds at link time only; L-3: binding by org unit crosses platforms) |
| 4 | Authentication, authorization, audit | **Pass** for authentication and authorization; **Gap** on audit completeness (L-8) |
| 5 | Network egress control | **Gap (deployment)**: LTI hosts were not in the allowlist. Fixed in this change. L-4: no timeout or size cap |
| 6 | Secrets and keys | **Pass**, with L-7 (key written by an unauthenticated route) |
| 7 | Policy 46 classification | **Pass** (classified per flow in `data-flow-inventory.md`) |

---

## Control 1 — Bounded capability surface — **Pass**

LTI adds five public routes, one route for a signed-in instructor, and two staff pages:

| Route | Who | What it can do |
|---|---|---|
| `GET /lti/jwks` | anyone | Publish the tool's public key. Empty when no enabled platform exists. |
| `GET`/`POST /lti/login` | the LMS, through the browser | Start a launch for a registered issuer. Refuses an unknown issuer with 403 before it writes anything. |
| `POST /lti/launch` | the LMS, through the browser | Verify an `id_token`, sign the user in, enroll a new member of a bound course. |
| `POST /lti/deep-link` | the holder of a picker ticket | Return a signed list of assignments to the LMS. |
| `POST /lti/deep-link/bind` | the holder of a signed bind token | Link an unbound LMS context to a course that the instructor teaches. |
| `/lti/bind` | a signed-in instructor | The same link, from a session. |
| `/admin/lti` | admin only (`RoleMiddleware(.admin)`, CSRF) | Register, edit, enable, disable and delete platforms. |
| `/instructor/lti-grades` | course staff; instructor for changes | Choose the grade transport, push all grades, link students by student number. |

Every route has one purpose. There is no general proxy or fetch route. With no
platform registered, `/lti/login` returns 403, `/lti/launch` returns 401,
`/lti/deep-link` returns 404 and the JWKS is empty (`LTI/LTIRoutes.swift:28-43`,
`LTI/LTIRoutes+Launch.swift:98-104`). The one exception is L-7.

---

## Control 2 — Data flow and egress (minimisation) — **Gap**

What crosses, per flow, is in `data-flow-inventory.md`. The minimisation is
good: Chickadee stores no grade on the sync row, discards the NRPS membership
after each read, keeps only hashes of the `state` value and the picker ticket,
and sends the LMS only an assignment's title, its maximum, a score and the
student's own LMS subject.

### L-1 (Medium) — service URLs are not bound to the platform host

Chickadee sends the platform's bearer token, and score bodies that hold the LMS
subject and the grade, to URLs that it does not check against the platform:

1. **The line-items and memberships URLs come from each launch.** Any signed
   launch, a student's included, replaces the course's stored URLs. The only
   check is `LTIPlatformForm.secureURL`, which accepts any `https` URL, and
   plain `http` on `localhost`, `127.0.0.1` or `::1`
   (`LTI/LTIRoutes+Launch.swift:292-305`, `LTI/LTIPlatformForm.swift:111-123`).
2. **The line-item `id` returned in the platform's JSON** becomes the target of
   the score `POST`, with no check (`LTI/LTIServiceClient.swift:89-105`,
   `LTI/LTIGradeSyncSweep.swift:152-156`).
3. **NRPS `Link: rel=next` URLs** are followed with no scheme or host check
   (`LTI/LTIServiceClient.swift:145-150,250-261`).

*Path.* A compromised platform, or a value that a platform returns by mistake,
can direct Chickadee to send its token and student grades to another host. The
loopback exception lets it reach a service on the Chickadee host itself, with a
bearer token attached. No SSRF guard applies: the guards in
`Helpers/ContentAttachmentStore.swift` and
`MCP/Tools/SupportFileURLFetcher.swift` are not used by LTI.

*Remediation.* Accept a service URL only when its host matches a host the admin
registered for the platform (the issuer, token or JWKS host, or an explicit
list), at all three points. Refuse the loopback exception outside a test build.

---

## Control 3 — Identity and account boundary — **Gap**

`docs/lti-1-3.md` §"Identity" states: "A launch never links to an admin or MCP
account". That holds when the link is made. It does not hold for a link that
already exists.

### L-2 (Medium) — the admin and MCP refusal holds at link time only

`LTIIdentityResolver.linkOrCreate` refuses an admin or MCP account
(`LTI/LTIIdentityResolver.swift:148`). The first step,
`linkedUser`, returns the account of an existing (platform, subject) link with
no such check (`:64-66,105-113`). Two paths lead an LMS subject into an admin
account:

1. An account that already has an LTI link is later made admin on
   `/admin/users/:id/role`. Its LMS subject keeps signing in to it.
2. On a platform with **Trust username** on, a launch whose `custom.username`
   names an SSO admin who has not yet signed in creates a `duo-oidc` stub with
   no subject (`:69-72,154-166`). The admin's first DUO sign-in adopts that stub
   (`Routes/Web/SSOAuthRoutes.swift:322,366-379`), and the
   `SSO_ADMIN_USERS` allowlist makes it admin (`:44,277-283`). The LMS subject
   that made the stub now signs in as that admin.

*Remediation.* Apply the admin and MCP refusal on every resolution, not only
when a link is made, and refuse the launch with the existing `linkRefused`
failure. Correct the sentence in `docs/lti-1-3.md` in the same change.

### L-3 (Medium) — binding by org unit crosses platforms and is not audited

An unbound context binds itself to the one course whose LEARN org unit ID equals
`context.id` (`LTI/LTICourseBinding.swift:23-31`). The match does not check
which platform sent the launch, and any launch triggers it, a student's
included. Later launches from that context enroll new users at the role they
claim, instructor included (`LTI/LTIRoutes+Launch.swift:267-275`). Nothing
records this binding in the audit log. (The deep-link bind path is audited, at
`LTI/LTIDeepLinkRoutes.swift:134-137`.)

*Path.* With a second platform registered (for example, a Canvas or Moodle
instance), a context whose ID equals a Brightspace org unit ID binds the
Brightspace course to the wrong platform. Both LMSs use small integers for
course IDs, so a collision is plausible. An instructor of the other LMS course
then becomes an instructor of the Chickadee course on first launch.

*Remediation.* Limit binding by org unit to the platform whose host matches the
course's Valence `BRIGHTSPACE_URL`, or to a platform flag the admin sets. Audit
the binding as `lti.course_bound` with an actor of `lti`.

### What passes

- A launch never changes an existing enrollment, so it cannot raise a role that
  Chickadee already holds (`LTI/LTIRoutes+Launch.swift:267-275`).
- **Trust username** is off by default and only an admin can set it
  (`LTI/LTIPlatformForm.swift:22,95`).
- "Link students" links only an exact, unique student-number match, and refuses
  admin and MCP accounts (`Routes/Web/InstructorLMSRoutes+LTIGrades.swift:213-224`).
- A launch rotates the session ID (`LTI/LTIRoutes+Launch.swift:218-221`), the
  same sequence as local and SSO sign-in.

---

## Control 4 — Authentication, authorization, audit

### 4a. Launch validation — **Pass**

`LTI/LTILaunchValidator.swift` and `LTI/LTILaunchClaims.swift` check:

- the signature, against the platform's key set only;
- `iss` equals the registered issuer; `aud` contains the client ID; `azp`
  equals the client ID when present or when there are several audiences;
- `exp` and `iat`, with 60 s leeway;
- `deployment_id` is in the registration's list;
- `version` is `1.3.0` and the message type is a resource-link or deep-linking
  request;
- the nonce equals the nonce stored with the single-use `state`
  (`LTI/LTIRoutes+Launch.swift:163-193`, `Helpers/SingleUseRecord.swift:22-28`).

### L-6 (Low) — smaller validation gaps

- The algorithm is not pinned in Chickadee. jwt-kit 5.7.1 selects it from the
  platform's key set (`LTI/LTIPlatformKeyCache.swift:55,84`). No test shows
  that a token with `alg: none` or `HS256` is refused.
- The maximum age for `iat` that `LTI/LTILaunchClaims.swift:14-15` describes is
  not implemented. `nbf` is not checked. The `target_link_uri` claim is not
  compared with the login request. The 300 s single-use `state` limits the
  effect of each gap.

*Remediation.* Add negative tests for `alg: none` and `HS256`. Implement the
documented `iat` age, or remove the comment.

### 4b. Authorization — **Pass**

Platform management is admin only. The grade-transport choice, "Push all" and
"Link students" need the instructor role in the course; a TA can read the page.
A deep-link pick checks again that the stored user is TA or instructor in the
course. The picker ticket is single-use and only its SHA-256 is stored.

### L-5 (Low) — no rate limit on the LTI routes

`LoginRateLimitMiddleware` covers `/login` and `/register` only
(`Middleware/LoginRateLimitMiddleware.swift:77-78`). The LTI routes are outside
it (`routes.swift:16-23`). Each `/lti/login` for a known issuer writes one row,
which the hourly reaper removes. The exposure is load, not access.

### L-8 (Info) — audit gaps

The nine `lti.*` actions record the actor, the address and the user agent
(`Services/AuditLogger.swift:54-64`). A launch is audited as
`auth.login_success` with `method: lti`, and an account it creates as
`user.provisioned`. These events are not audited:

- a change to a platform's **Trust username** flag (the edit records only the
  issuer and the client ID, `Routes/Web/AdminRoutes+LTI.swift:89-91`);
- the binding by org unit (L-3);
- an enrollment that a launch creates;
- a failed launch (it goes to the log only).

*Remediation.* Record `trust_username` in the `lti.platform_updated` metadata,
and audit the binding and the enrollment.

---

## Control 5 — Network egress control — **Gap (deployment)**

LTI adds outbound calls to each registered platform: its JWKS URL, its token
URL, and its AGS and NRPS service URLs. These were not in
`deploy/egress-allowlist.md`. **This change adds them.**

### L-4 (Low) — no timeout or response-size cap

The JWKS, token, AGS and NRPS calls set no timeout and no response-size limit
(`LTI/LTIPlatformKeyCache.swift:105-113`, `LTI/LTIServiceClient.swift`). The
shared client carries only the proxy setting (`APIServerApp.swift:117-120`). A
slow or large answer holds a request or the 60 s sweep. NRPS paging stops at
100 pages.

---

## Control 6 — Secrets and keys — **Pass**

- **Tool key.** RSA 2048, generated on first use at
  `<workingDirectory>/.lti-tool-key` with mode 0600
  (`LTI/LTIToolKeyCache.swift:37-43`, `Utilities/SecretFile.swift:18-25`). No
  environment variable. The `kid` is the RFC 7638 thumbprint. The private key is
  never logged or returned.
- **Rotation.** Replace the file and restart. The `kid` changes. There is no
  overlap period, so an LMS that caches the old key set refuses the tool's
  assertions until it fetches again.
- **No stored secrets.** A registration holds the issuer, client ID, deployment
  IDs, four URLs, an optional token audience, a display name and two flags
  (`Migrations/CreateLTIPlatforms.swift:17-31`).
- **Access tokens** are kept in memory only, until one minute before they
  expire, and dropped on a 401.

### L-7 (Low) — an unauthenticated route writes the tool key

`POST /lti/deep-link/bind` verifies any posted `token` with the tool key before
it checks for a platform (`LTI/LTIDeepLinkRoutes.swift:106-107`). On a
deployment with no platform, one anonymous request generates and writes
`.lti-tool-key`. This breaks compatibility rule 1 in `docs/lti-1-3.md` ("No
platform, no change") and the comment at `LTI/LTIRoutes.swift:19-21`. It
exposes nothing.

*Remediation.* Refuse the request with 404 when no enabled platform exists,
before the key is loaded.

---

## Control 7 — Policy 46 classification — **Pass**

Each LTI flow has a classification in `data-flow-inventory.md`. The launch,
AGS and NRPS flows are **Restricted** (name, email, LMS subject, grade, student
number). The login and deep-linking flows are **Confidential**.

### Logging and retention

- No LTI log line carries an email, a name, an LMS subject, a student number, a
  grade, an access token or an `id_token`. A launch that is refused a link to an
  existing account logs the username as metadata
  (`LTI/LTIRoutes+Launch.swift:204-205`). The admin `query_logs`
  ring buffer redacts it (`MCP/Admin/RingBufferLogHandler.swift:58-62`), as the
  F-1 convention requires. The platform's `error` string on a refused launch is
  logged as sent, with no length limit (`LTI/LTILaunchFailure.swift:72`).
- The hourly reaper deletes expired or used login states and picker tickets
  (`LTI/LTIRecordReaper.swift:20,30-46`).
- `lti_identities` rows are kept until the user or the platform is deleted.
- **L-9 (Info).** `lti_grade_syncs` rows are deleted with the user, but not with
  the course or the assignment (`Migrations/CreateLTIGradeSyncs.swift:12`). A
  row that is not pending stays when its assignment is deleted. It holds a user
  ID, a test setup ID, a time and a failure sentence, and no grade.

---

## Verify at deployment

The repository cannot prove these. They need operator confirmation.

1. **Production already has a registration.** On 2026-10-09 the admin
   diagnostics tool `query_audit_log` (counts only, 90-day window) reported one `lti.platform_registered`, two
   `lti.platform_updated`, one `lti.course_bound` and one `lti.content_linked`.
   It reported no `lti.grade_transport_changed`, so no course has chosen the
   AGS transport. `docs/lti-1-3.md` §"Compliance" asks
   for the IRA before a production registration. Confirm that the IRA request
   is filed, or that this registration is a test that students do not use.
2. **Trust username.** Confirm whether the production platform has it on. L-2
   path 2 needs it.
3. **Egress.** Add the platform's hosts to the deployment allowlist
   (`deploy/egress-allowlist.md`).

---

## Findings (index)

| ID | Control | Finding | Severity | Status |
|----|---------|---------|----------|--------|
| L-1 | Egress | Service URLs from launches, line-item IDs and NRPS next links are not bound to the platform host; loopback `http` accepted | **Medium** | Open |
| L-2 | Identity | Admin and MCP refusal holds at link time only; an existing link, or an SSO-adopted stub, signs in as an admin | **Medium** | Open |
| L-3 | Identity | Binding by org unit ignores the platform and is not audited | **Medium** | Open |
| L-4 | Egress | No timeout or response-size cap on platform calls | Low | Open |
| L-5 | AuthN | No rate limit on the LTI routes | Low | Open |
| L-6 | AuthN | Algorithm pinning untested; `iat` age and `nbf` not checked; `target_link_uri` not compared | Low | Open |
| L-7 | Keys | `POST /lti/deep-link/bind` writes the tool key with no platform registered | Low | Open |
| L-8 | Audit | Trust-username changes, binding by org unit, launch enrollments and failed launches not audited | Info | Open |
| L-9 | Retention | `lti_grade_syncs` rows outlive their course and assignment | Info | Open |

**Recommended before students use LTI in production:** L-1, L-2 and L-3. Fix
L-3 before a second platform is registered.
