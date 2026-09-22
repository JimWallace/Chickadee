### Fixed

- **TLS certificate renewal works through the campus-only port 80 firewall.** The production certificate expired on 2026-09-22 because IST's Salt-managed firewall allows port 80 only from campus, so every Let's Encrypt HTTP-01 renewal timed out. New certbot hooks in `deploy/certbot-hooks/` open port 80 for the duration of a renewal attempt, close it after, and reload nginx after a successful renewal. `deploy/README.md` gives the install and test steps.
