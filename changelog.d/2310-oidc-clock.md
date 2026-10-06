### Fixed

- **The OIDC retry cooldown uses one clock.** `resolve(app:now:)` compared the caller's `now` against a cooldown that it had set from the wall clock, so a caller that passed a time saw a cooldown it could not control. The cooldown now starts from the caller's `now`. A stale comment about the logout token revocation is also corrected. (#2310)
