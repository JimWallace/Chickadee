### Added

- **Student-managed slip days (#1228).** Courses can enable a per-student
  budget of self-serve deadline extensions (default 2 × 24 h, both
  configurable). After a deadline passes, an eligible student claims a slip
  day from a dashboard calendar action via an explicit confirmation page;
  days stack on a single assignment, and each claim must land inside the
  window the student currently holds. Spends write ordinary per-student
  extension rows, so every existing deadline gate applies unchanged, and the
  spend itself is a serialized atomic transaction (no double-spend from a
  double-click). Balances show under the dashboard course heading and on
  `/account`. A new instructor **Slip days** tab carries the course policy
  (instructor-only), the roster ledger, ±1 budget adjustments, and refunds
  that recompute or remove the extension (TA+). Slip-day policy travels in
  `.chickadee` course bundles; spends land in the audit log and the
  student's personal data export. Staff-granted extensions always take
  precedence — the offer is hidden while one exists. See `docs/slip-days.md`.
