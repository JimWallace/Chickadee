### Security

- **Replay protection and login rate-limits now hold across server processes
  (#1154).** Worker-HMAC nonces move from a per-process in-memory store to a
  `worker_nonces` table where first-seen is an atomic PRIMARY KEY insert — a
  signed request captured on one instance can no longer be replayed against
  another within the TTL window. Login brute-force state (per-IP window,
  per-username lockout) moves to a `login_attempts` table, so N instances
  behind a load balancer no longer multiply the configured rate cap by N or
  count lockout failures per-instance. Both tables self-clean (per-key prune
  on write plus throttled sweeps). This also removes the old nonce store's
  full-dictionary rebuild on every worker request.
