### Added

- **Chickadee avatar artwork.** `Resources/Views/_avatar-sprite.leaf` draws the
  generated student avatar — a symmetrical, front-facing bird: cap, cheeks,
  bib, belly, six folded-wing patterns drawn once and mirrored, beak and eyes — with an `--avatar-*` palette in `Public/styles.css`
  (8 cap families × 4 cheeks × 6 flanks × 8 backdrops × 6 wings = 9,216 birds).
  `Tools/avatar-preview/preview.mjs` renders a contact sheet from the sprite and
  the stylesheet. Art only: nothing renders an avatar yet.

### Changed

- **`check-styles.sh` guard S4 admits a second sprite.** Drawn geometry may now
  live in `_avatar-sprite.leaf` as well as `_icons.leaf` — two distinct
  vocabularies for two distinct sets of pages — and nowhere else.
