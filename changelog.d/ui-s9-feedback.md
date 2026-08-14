### Changed

- **Two feedback channels, not six (audit S9).** Blocking errors now appear as
  an inline banner next to the thing that failed, replacing every remaining
  native browser alert box in the UI — including inside the suite editor, where
  one control reported upload failures inline but delete failures in a modal.
  Progress and status lines are now announced to screen readers.

### Fixed

- **Confirmation messages after a redirect now show on every page.** The flash
  banner was rendered by only nine pages, so a successful action that
  redirected anywhere else completed silently with no confirmation. It now
  renders once for the whole site.
