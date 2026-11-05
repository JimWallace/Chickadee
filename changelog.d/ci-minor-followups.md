### Fixed

- **The weekly token check tests write access.** `dependency-health.yml` checked `RELEASE_TOKEN` with read requests only, so a token without Contents or Pull requests write passed until a real push or pull request failed. It now sends one request of each kind that GitHub must refuse, and reads the refusal: 403 means the permission is missing, 422 means it is there. Nothing is created.
- **The ZAP scan courses are in the current term.** `scripts/zap-signed-in-session.sh` created its two courses in Fall 2026, a fixed term. It now uses the current term, on the calendar that `TermSeason.current` uses.
