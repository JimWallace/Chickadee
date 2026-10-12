### Changed

- **The admin pages render with Elementary.** Overview, Health Alerts, People, Storage, Retention, Audit Log, LEARN, MCP, LTI and GitHub, and the polled runner and people rows, are now type-checked Swift views. One `AdminTabs` component renders the version banner and the tab bar for all of them. Each port was compared with its Leaf output, and the markup is the same apart from attribute escaping. The poll endpoints still answer 304 when nothing changed. The Leaf templates for these pages and their partials are removed.

### Fixed

- **An empty flash message no longer shows an empty banner on Health Alerts.** A bare `?ok=` or `?error=` in the URL drew an empty banner. The page now ignores empty values.
- **An account with an empty display name shows its username on People.** Before, the row sorted by an empty name and showed its username twice.
