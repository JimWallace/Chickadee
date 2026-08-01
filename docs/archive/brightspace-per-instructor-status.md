# BrightSpace per-instructor grade sync — status

_Snapshot: 2026-06-20. Owner: jrwallac (james.wallace@uwaterloo.ca)._

Where the per-instructor BrightSpace grade-sync work stands, the blocker we hit
during pilot prep, and the decision for unblocking it. For the operator runbook
see [brightspace-setup.md](brightspace-setup.md); for runtime design see
[architecture.md → BrightSpace grade sync](architecture.md).

## TL;DR

All code is **merged and complete**. The pilot is blocked on a **D2L LMS policy
gate**, not on Chickadee: UW LEARN currently only lets the `sphs-dev` service
account authorize the Valence app and mint a User Key — instructor accounts
can't. The agreed unblock is **Path B**: enroll `sphs-dev` in the pilot course
*with grade-write* next week, then drive the pilot through the deployment-wide
service-account fallback. The per-instructor machinery stays in place for the
day IST lets instructors authorize the app (**Path A**).

## What shipped (all merged to `main`)

| PR | What |
|----|------|
| #974 | UW Valence client hardening (version negotiation, pagination, clock-skew, signing) |
| #975 | Phase 1 + 3 — per-instructor credentials + identity-aware sync |
| #976 | Phase 2 — instructor self-serve org-unit binding (binder = default identity) |
| #977 | Phase 4 — sync-identity health visibility + docs |

The model as built:

- **Per-instructor (Path A).** Each instructor connects their own LEARN account
  on the instructor **LEARN** tab ("Connect my LEARN account"), pasting a Valence
  User ID + Key. Each course designates one connected instructor as its grade-sync
  identity (`courses.brightspace_sync_user_id`); pushes run *as that instructor*.
  Binding the org unit makes the binder the sync identity. A course whose
  designated instructor has disconnected shows **"needs reconnect"** and **defers**
  (results stay pending, nothing lost) until someone reconnects or takes over.
- **Service-account fallback (Path B).** A deployment-wide
  `BRIGHTSPACE_USER_ID`/`BRIGHTSPACE_USER_KEY` used for any course with no
  designated instructor. Retained deliberately.

## The blocker (the catch-22)

Harvesting a User Key against UW LEARN with the **`jrwallac`** instructor login
fails with:

> This application is not authorized on this LMS instance. Ask your administrator
> to authorize this application.

The **same** harvester, host, and App ID/Key succeed when logging in as the
**`sphs-dev`** service account. Because the only variable is the login, this is
**not** an instance-level app-trust problem (sphs-dev proves the App ID is
trusted on the instance) and **not** a Chickadee problem — it's D2L's
**per-user/role authorization gate**: only certain accounts are permitted to
authorize that app and mint a key.

That produces the standoff:

> The account that **can mint a key** (`sphs-dev`) **isn't enrolled to write
> grades**; the accounts that **are enrolled to write grades** (instructors like
> `jrwallac`) **can't mint a key**.

## Decision

**Pilot via Path B.** Next week, when staff are back in the office, enroll the
`sphs-dev` service account in the pilot course **with a grade-write role**
(TA or Instructor — *not* Student/Observer; a plain enrollment won't push
grades). Then:

1. Set `BRIGHTSPACE_USER_ID` / `BRIGHTSPACE_USER_KEY` to the `sphs-dev` pair
   (env, or **Admin → BrightSpace → Set credentials manually** — no restart).
2. **Link course** to its org unit (`1106038`).
3. Map the assignment to a grade item.
4. Submit as a test student → confirm the grade pushes as `sphs-dev`.

With no course designating an instructor, sync falls back to the service-account
key automatically, so nothing per-instructor needs configuring for the pilot.

**Path A stays available.** If/when IST grants the instructor role permission to
authorize App ID `<id>` on the LEARN instance (mark the app usable by all users /
grant the instructor role the API-application authorization permission),
`jrwallac` can connect their own key and grades attribute to the real
instructor — no code change needed.

## Open items

- [ ] **Next week:** enroll `sphs-dev` in the pilot course with grade-write (org
      unit `1106038`).
- [ ] Configure the deployment-wide service-account key; run the end-to-end push
      test (steps above).
- [ ] **(Path A, later)** Ask IST to let the instructor role authorize the app.
- [ ] **Security:** rotate the secrets that passed through chat during setup
      (App Key, any harvested User Keys, OIDC client secret, Slack webhook, DB
      passwords).
- [ ] Drop the moot `sphs-dev-enroll.csv` scratch file (service account is
      enrolled in LEARN directly, not via Chickadee).

## UI fine-tuning backlog (weekend)

Candidates on the instructor **LEARN** tab, none blocking the pilot:

- Tighten the **"Your LEARN account"** section — the connected / "needs
  reconnect" / "no identity" states are three separate notes; consider one
  status line with a state badge.
- The **"Org-unit link"** section now shows a status line *and* a bind form;
  collapse to a single compact block (status + inline edit).
- "connected since" wording/format; surface key age so a stale key is obvious.
- When multiple co-instructors are connected, make the "who is the sync identity"
  picker explicit rather than first-come / manual takeover only.
- "Test connection" button feedback (success/latency affordance).

(Render tests prove the templates resolve but don't exercise page JS — anything
JS-driven wants a manual look. Note the LeafKit 1.14.2 caveat: no inline `#if`
without its `:` colon, and avoid `#if` nested inside an `#if/#else` — see #977.)
