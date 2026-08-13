### Fixed

- **Six shipped UI defects no guard could see.** Section drag-and-drop showed
  no drop indicator (the classes were assigned but styled nowhere); the
  account page's badges, admin-audit's filter form and its `btn--secondary`,
  and admin-brightspace's `tier-public` all referenced classes that exist in
  no stylesheet, rendering unstyled; and a dead `test-output-row-*` class
  family shipped on every submission page.

### Changed

- **Page rendering rules now live in one place and are enforced.**
  `docs/ui-design.md` gains page archetypes and a closed component
  vocabulary; flash banners render only through the new `_flash` partial
  (with ARIA roles — the second, role-less banner dialect is gone); the
  admin/instructor tab bars are shared partials instead of fourteen
  copy-pasted copies; `.admin-section` is renamed `.page-section`; five
  bespoke page-header families collapse onto `.page-titlebar`; and the
  idle-logout dialog's JS-injected stylesheet (nine hardcoded colours, a
  private dark-mode block) moves onto the palette in `styles.css`.

### Added

- **Three new UI drift guards** in the `check-styles.sh` family: every
  assigned class name must resolve to a stylesheet rule (`js-` prefix for
  behaviour-only hooks; interpolated families pinned by a Swift
  `CaseIterable` test), page `<style>` totals and JS styling decisions
  ratchet down only, and the nginx maintenance page's colours must stay a
  subset of the app palette. Visual-regression + axe coverage grows from 6
  to 13 pages — one per archetype — with a shared page list and per-page
  baseline bootstrap.
