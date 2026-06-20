# BrightSpace grade sync — setup & testing

How to wire Chickadee to a D2L BrightSpace course so submission grades flow
into the LEARN gradebook, and how to test it end-to-end against UW's
`learntest` environment.

For the runtime design (sync engine, debounce, audit log), see
[architecture.md → BrightSpace grade sync](architecture.md). This doc is the
operator runbook.

## The auth model in one paragraph

Chickadee uses D2L's Valence **"App + User" key signing**. Every request is
signed with two HMAC-SHA256 keys: the registered **app** key and a **user**
key. There is no token endpoint — signatures are computed per request
(`BrightSpaceAPIClient.signed(url:method:)`).

There are two identity models for the **user** key:

- **Per-instructor (UW).** Each instructor connects their own LEARN account on
  the instructor **LEARN** tab ("Connect my LEARN account"); each course
  designates one connected instructor as its grade-sync identity, and pushes run
  *as that instructor*. This is the model UW requires — a shared service account
  can't be enrolled in courses, but instructors already are, so their key carries
  the grade-write permission. See "Per-instructor identity" below.
- **Deployment-wide service account (fallback).** A single env- or admin-
  authorized key, used for every course that has no designated instructor. Where
  a grade lands is then decided by two IDs (org unit + grade object), **not** by
  the credentials.

## Per-instructor identity

Set up the deployment with only the three **app** vars (`BRIGHTSPACE_URL`,
`BRIGHTSPACE_APP_ID`, `BRIGHTSPACE_APP_KEY`) — no `BRIGHTSPACE_USER_*`. Then each
instructor connects their own LEARN account:

1. **Connect.** On the instructor **LEARN** tab → "Connect my LEARN account",
   paste a Valence **User ID + User Key** minted for *their* account (UW: from the
   credential harvester `d2l-api-cred.fast.uwaterloo.ca`, Step 1C). Chickadee
   `whoami`-verifies it and stores it against that instructor
   (`brightspace_credentials.user_id`). Connecting also makes them the active
   course's grade-sync identity if it has none yet.
2. **Designate / reassign.** Each course pushes grades as one designated
   instructor (`courses.brightspace_sync_user_id`). Any connected co-instructor
   can take over with "Use my account for this course".
3. **Bind + map as usual.** Org-unit binding (admin, course page), grade-item
   mapping, and student matching (Steps 4–6) are unchanged — they just run as the
   course's designated instructor's key.

A course whose designated instructor hasn't connected yet **defers**: its results
stay pending and push automatically once someone connects, so nothing is lost. If
no instructor is designated, grade sync falls back to the deployment-wide service
account (below), when one is configured.

## Credentials you need (four secrets + the URL)

| Env var | What it is | Where it comes from |
|---|---|---|
| `BRIGHTSPACE_URL` | LMS base URL | e.g. `https://learntest.uwaterloo.ca` |
| `BRIGHTSPACE_APP_ID` | Application ID | D2L admin registers the app (UW: IST) |
| `BRIGHTSPACE_APP_KEY` | Application Key | issued with the App ID |
| `BRIGHTSPACE_USER_ID` | User ID for the service account | **Valence handshake** (below) |
| `BRIGHTSPACE_USER_KEY` | User Key for the service account | **Valence handshake** (below) |
| `BRIGHTSPACE_SYNC_DEBOUNCE_SECS` | optional, default `90` | lower it for testing |

The App ID/Key alone **cannot authenticate a single call** — the user pair is
what proves the service account authorized the app. The app registration and
the user handshake are two separate steps.

> **These are all secrets.** They live only in the server's environment
> (ops-managed) and are never shown in the UI or committed to the repo.

## Step 1 — Obtain the User ID + User Key

There are a few ways to capture the Valence user key. On a **deployed server**
whose own callback is the app's Trusted URL, use the in-app authorize flow (1A);
where a **central credential service** is the Trusted URL instead (e.g. UW),
harvest the key there and paste it in (1C); for **local/scripted** setup use the
CLI helper (1B).

> **Auth scheme note.** This is D2L's legacy **ID-Key Auth** (the
> `x_a`…`x_t` HMAC signing), which is what an "Application ID + Application Key"
> registration uses. D2L recommends OAuth2 for new work, but OAuth2 needs a
> different registration (a Client ID/Secret + redirect URI + scopes). Request
> signing is the `<METHOD>&<lowercase_path>&<timestamp>` base string, verified
> against Brightspace's `valence-sdk-python`.

### Step 1A — Authorize in the admin UI (recommended on a deployed server)

With `BRIGHTSPACE_URL` / `BRIGHTSPACE_APP_ID` / `BRIGHTSPACE_APP_KEY` set in the
server environment and `PUBLIC_BASE_URL` pointing at the deployment, an admin
opens **Admin → BrightSpace → "Authorize BrightSpace"**. This redirects to D2L;
log in as the **service account** (e.g. `sphs-dev`) and authorize. D2L redirects
back to `{PUBLIC_BASE_URL}/admin/brightspace/valence-callback`, the server
captures + `whoami`-verifies the user key, stores it (single active row,
table `brightspace_credentials`), and **rebuilds the live client** — grade sync
picks it up within one sweep (≤60 s), no restart.

- The callback URL must be covered by the app's registered **Trusted URL**
  (e.g. `chickadee.uwaterloo.ca`).
- A stored (authorized) key **takes precedence** over `BRIGHTSPACE_USER_KEY` in
  env; env stays the bootstrap fallback. "Clear authorization" drops the stored
  key and reverts to env (or disables sync).
- The captured key rides in D2L's redirect query string, so it lands in the
  host's access log once — treat it as rotatable.

### Step 1C — Central credential service + manual entry (e.g. UW)

Some institutions register a **central credential-harvesting service** as the
app's Trusted URL rather than each app's own callback. UW's is
`https://d2l-api-cred.fast.uwaterloo.ca` (registered with **no trailing slash**).
In this model the in-app "Authorize" button (1A) can't work — D2L only ever
redirects to that central service, never to this server. Instead:

1. Open the harvester (UW: `https://d2l-api-cred.fast.uwaterloo.ca`) in a
   **private/incognito** window, enter the LMS host + App ID + App Key, and
   authenticate **as the service account** (e.g. `sphs-dev`), *not* your personal
   login. It returns a **User ID** and **User Key**.
2. In Chickadee, go to **Admin → BrightSpace → "Set credentials manually"**,
   paste the User ID + User Key, and save. Chickadee `whoami`-verifies the pair,
   stores it (same `brightspace_credentials` row, taking precedence over env),
   and rebuilds the live client — no env change or restart.

This is the supported path at UW: the env-key model with the key sourced from the
harvester. The stored key acts as whatever account you logged into the harvester
as, so use the **service account** for a shared, person-independent grade sync.
(You can also drop the harvested values into `BRIGHTSPACE_USER_ID` /
`BRIGHTSPACE_USER_KEY` in env instead — the manual-entry form just avoids the
restart.)

### Step 1B — CLI helper (local / scripted)

Run the one-time interactive handshake helper. It builds the signed Valence
auth URL, opens it, captures D2L's redirect, and verifies the captured pair
with a live `whoami` call. Stdlib only — no `pip install`.

```bash
export BRIGHTSPACE_URL=https://learntest.uwaterloo.ca
export BRIGHTSPACE_APP_ID=...      # Application ID
export BRIGHTSPACE_APP_KEY=...     # Application Key
scripts/brightspace-valence-auth.py
```

Then:

1. The helper opens a browser to the LMS auth handler. **Log in as the D2L
   service account** whose grade-write permission you want to use (e.g.
   `sphs-dev`), not your personal account.
2. Authorize the app.
3. D2L redirects to `http://localhost:8088/callback?x_a=<userId>&x_b=<userKey>`;
   the helper captures both, confirms them via `whoami`, and prints:

   ```
   BRIGHTSPACE_USER_ID=...
   BRIGHTSPACE_USER_KEY=...
   ```

The helper only prints the pair to your terminal — it never writes them to
disk. If the browser can't reach `localhost` (e.g. you're on a remote box),
run it locally with `--no-browser` and open the printed URL yourself, or
forward the port. Use `--port N` if `8088` is taken.

> **"x_target does not match the allowed values for this application."** D2L
> validates the callback (`x_target`) against the **Trusted URL** registered
> for the app, by prefix. If the auth page shows this error, the app's
> Trusted URL doesn't cover `http://localhost:8088/callback`. Either ask your
> D2L admin to add `http://localhost` to the allowed-redirect list, or — if a
> Trusted URL is **already** registered for a real host — use `--callback`
> (below). This is configured entirely on the D2L side; no change to the
> helper bypasses it.

### Using an already-approved Trusted URL (`--callback`)

If the app's Trusted URL is already a real host (e.g. UW approved
`chickadee.uwaterloo.ca`), point the helper at it instead of localhost:

```bash
scripts/brightspace-valence-auth.py \
  --callback https://chickadee.uwaterloo.ca/brightspace-valence-callback
```

D2L then redirects to *that host*, not localhost, so the helper can't catch
the redirect automatically — it prints the auth URL, you authorize, and you
**paste the redirected URL back** (read it from the browser address bar; the
page may 404, which is fine — the `x_a`/`x_b` values are in the URL). The
helper extracts the pair and verifies it via `whoami`.

> **Trade-off:** the redirect carries the User Key in its query string, so it
> transits that host's request path and lands in its access logs (nginx /
> Vapor). Loopback (the default) avoids this. When you use `--callback`
> against a shared host, treat the resulting key as **disposable** — revoke /
> rotate it (D2L manage-extensibility) once testing is done or a durable
> server-side authorize flow exists.

## Step 2 — Put the vars in the server's environment

Set the deployment app creds + URL wherever the server runs. With Docker
Compose they're already plumbed through `docker-compose.yml`; put them in your
`.env`:

```
BRIGHTSPACE_URL=https://learntest.uwaterloo.ca
BRIGHTSPACE_APP_ID=...
BRIGHTSPACE_APP_KEY=...
# User key: omit these if you authorize via the admin UI (Step 1A); set them
# only for the env-supplied / CLI-helper path (Step 1B).
BRIGHTSPACE_USER_ID=...
BRIGHTSPACE_USER_KEY=...
BRIGHTSPACE_SYNC_DEBOUNCE_SECS=10
```

On startup the log emits a redacted `brightspace: baseURL=… appID=[set]
appKey=[redacted] …` line. With only the three app vars set it reads
`userKey=(awaiting authorize)` and grade sync stays idle until an admin
authorizes (Step 1A); with all four (env user key) or a stored authorized key,
`app.brightSpaceClient` is live.

> **Test against a non-prod Chickadee instance first.** `learntest` is D2L's
> test environment and the credentials are dev credentials — point a
> local/staging Chickadee at it before touching a production deploy.

If outbound egress is locked down (`deploy/egress-allowlist.md`), allow the
D2L host (`learntest.uwaterloo.ca`, prod: `d2l.uwaterloo.ca`).

## Step 3 — Verify the connection (whoami)

In Chickadee: **Instructor → BrightSpace tab → "Test connection"**. It calls
D2L `whoami` and should report **"Connected as … (sphs-dev)"**. This is the
fastest auth smoke test — a bad key pair fails here, before any grade is at
risk. (The helper in Step 1 already runs the same check, so if that passed
this should too.)

## Step 4 — Bind the course to its org unit (admin only)

A grade lands in a D2L **course**, identified by its **org unit ID** — the
number in the course URL: `…/d2l/home/1106038` → org unit `1106038`.

As an **admin**, on the Chickadee **course page**, set the BrightSpace
org-unit ID. The server verifies it on save (`getOrgUnit`) and caches the D2L
course name back into the page — **confirm that name matches** the course you
intended. This is admin-only because the service account can usually write to
many courses; instructors are then locked to their bound course.

## Step 5 — Map each assignment to a grade item

On the BrightSpace tab, every assignment shows a **grade-object** dropdown
populated from the course's LEARN gradebook (`listGradeObjects`, free-text
fallback). Create the grade items in `learntest` first if needed, then map
each Chickadee assignment to the column it should write to.

## Step 6 — Match student identities

Grades route by **student number**: a Chickadee user's `student_id` must equal
the D2L **OrgDefinedId** of the matching LEARN account. Enroll the test
students in your Chickadee course with their `learntest` org-defined IDs. The
BrightSpace tab's **classlist reconcile** and **"unmapped students"** list flag
anyone who can't be resolved (no student ID on file, or not found in
BrightSpace).

## Step 7 — End-to-end test

1. Submit as a test student and let it grade.
2. `ResultRoutes` flags the result row pending; `BrightSpaceGradeSyncMonitor`
   sweeps every 60 s and pushes the **best (max) points** per
   (student, assignment) once past the debounce window. Click **"Sync now"**
   on the tab to bypass the debounce immediately.
3. Confirm the grade appears in the **`learntest` gradebook**.
4. Watch the **sync-activity log** on the tab (success / failure / skipped),
   and use **"Retry failed"** / per-assignment **"Push all"** as needed.

For ops-level diagnosis, the admin diagnostic MCP surface exposes
`get_brightspace_sync_status` (counts by status + recent D2L error detail,
student-free).

## Troubleshooting

- **"x_target does not match the allowed values" (Step 1):** the app's
  registered Trusted URL doesn't cover the localhost callback. Have your D2L
  admin add `http://localhost` to the application's allowed-redirect list (see
  the Step 1 note).
- **whoami fails (Step 3):** wrong `BRIGHTSPACE_URL`, expired/incorrect key
  pair, or you logged in as the wrong account in Step 1. Re-run the helper.
- **Org-unit save shows "unverified":** the ID is wrong, or D2L was
  unreachable (egress). Verification failures don't block the save — the
  cached name just stays empty.
- **Student shows as unmapped:** missing `student_id` in Chickadee, or it
  doesn't match the LEARN OrgDefinedId. Fix the enrollment record.
- **Grade pushed but not visible:** confirm the grade item is the right column
  and the assignment is mapped to it; check the sync log row's detail.
