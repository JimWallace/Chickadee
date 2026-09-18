### Added

- **Mascot icon set.** Ten new chickadee illustrations covering the states the
  UI already has surfaces for: home, 404, 500, success, empty, studying,
  writing, achievement, grading and welcome. `Assets/` holds the 384x384
  sources; a copy is served from `Public/images/` only once a surface uses it,
  sized to its display box rather than shipped at source size.
- **The sign-in page and the error page now show a matching mascot.** Login
  gets the waving bird; the error page picks the signpost bird for a 404 and
  the tangled-cable bird for a 5xx, keeping the neutral bird for every other
  status.

### Changed

- **`docs/ui-design.md` now covers mascot imagery.** The component vocabulary
  had no entry for images at all, so each new pose would have decided its own
  semantics, alt text and served size with nothing to consult. The rules: the
  nav mark stays neutral, a pose belongs only on a single-state page, a pose
  keeps `alt=""` only where adjacent text states that state, and a served copy
  is sized to its display box.

### Fixed

- **The error page no longer circle-crops its mascot.** `.error-bird` carried a
  `border-radius: 50%` that clipped the corners of any illustration wider than
  the bird itself. It was vestigial — every mascot PNG is already round with
  transparent corners.
