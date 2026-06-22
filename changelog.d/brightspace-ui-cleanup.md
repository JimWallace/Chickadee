### Changed

- **LEARN (BrightSpace) tab cleanup for the service-account model.** The
  instructor **LEARN** tab drops the per-instructor "Your LEARN account"
  connect/disconnect UI and the "Org-unit link" section (the override handlers
  stay in code, just unused) and opens straight at the grade-sync dashboard. The
  **Export Grades CSV** button moves to the top-right of the tab. A new
  **"Auto-map by name"** button maps every unmapped assignment to the D2L grade
  item whose name matches in one click (fills empty mappings only; safe to
  re-run). The admin **BrightSpace** tab is renamed **LEARN** and drops the
  in-app authorize / redirect-callback flow (UW uses a central credential
  service — the "Set credentials manually" path remains).
