### Added

- **In-app BrightSpace authorization (admin).** A new **Admin → BrightSpace**
  page performs the D2L Valence "App + User" handshake server-side: it redirects
  the admin to D2L, captures the user key on the `/admin/brightspace/valence-callback`
  redirect, verifies it with `whoami`, persists it (single-row
  `brightspace_credentials`), and rebuilds the live client so grade sync picks
  it up within one sweep — no env change or restart. A stored (authorized) key
  takes precedence over `BRIGHTSPACE_USER_KEY` in env; "Clear authorization"
  reverts to env (or disables sync). The deployment app creds
  (`BRIGHTSPACE_URL`/`_APP_ID`/`_APP_KEY`) stay env-only.
- **BrightSpace setup tooling.** `scripts/brightspace-valence-auth.py` performs
  the same handshake from the CLI (localhost or an approved `--callback` Trusted
  URL) for local/scripted setup, and `docs/brightspace-setup.md` documents the
  full credential → connection → org-unit → grade-item → roster → testing flow.

### Fixed

- **BrightSpace request signing.** The Valence per-request signature base string
  was `<timestamp>\n<METHOD>\n<path>`; the correct format (per Brightspace's
  `valence-sdk-python`) is `<METHOD>&<lowercase_path>&<timestamp>`. Every grade
  push / lookup would have failed authentication against a live D2L. Pinned by
  cross-language test vectors. (The bug was latent: grade sync had never run
  against a real server.)
