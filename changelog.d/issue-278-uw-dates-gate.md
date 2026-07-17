### Changed

- **UW important-dates integration is now an explicitly optional institutional
  feature (#278).** The due-date holiday/closure warnings fed by the UWaterloo
  important-dates iCal feed stay UW-specific by design (not generalized), and
  registration of `GET /api/v1/uw-dates` is now gated by
  `UW_IMPORTANT_DATES_ENABLED` (default on — UW deployments need no change).
  Non-UW deployments set it to `false` in `.env`; the endpoint is then absent
  and the assignment editors' warning fetch silently no-ops. This closes the
  last open half of #278 — the Marmoset-import half was already resolved by
  removal.
