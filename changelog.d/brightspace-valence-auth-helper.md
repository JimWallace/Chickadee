### Added

- **BrightSpace setup tooling.** `scripts/brightspace-valence-auth.py`
  performs the one-time D2L Valence "App + User" handshake interactively and
  prints the `BRIGHTSPACE_USER_ID` / `BRIGHTSPACE_USER_KEY` pair the grade-sync
  client needs (verified with a live `whoami`), and `docs/brightspace-setup.md`
  documents the full credential → connection → org-unit → grade-item → roster →
  end-to-end testing flow against `learntest`. No server code changes.
