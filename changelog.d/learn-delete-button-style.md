### Fixed

- **LEARN page Delete button matches the rest of the UI.** The Class Roster "Delete" button on `/instructor/brightspace` used a one-off solid-red `.btn-danger` style that stood out from every other action button. It now uses the shared `btn action-btn action-danger` class — the same subtle danger styling used across the instructor pages — and the page-local override (which also hardcoded a `#fff` colour) is removed.
