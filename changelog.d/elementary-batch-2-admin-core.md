### Changed

- **The admin Overview, People and Health Alerts pages render with Elementary.** These three pages, and the polled runner and people rows, are now type-checked Swift views. Each port was compared with its Leaf output, and the markup is the same apart from attribute escaping. The poll endpoints still answer 304 when nothing changed. The Leaf templates for the Overview, People and both row partials are removed.

### Fixed

- **An empty flash message no longer shows an empty banner on Health Alerts.** A bare `?ok=` or `?error=` in the URL drew an empty banner. The page now ignores empty values.
- **An account with an empty display name shows its username on People.** Before, the row sorted by an empty name and showed its username twice.
