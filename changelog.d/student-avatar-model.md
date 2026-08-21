### Added

- **`AvatarSpec` and `AvatarMarkup` (Core).** The five-slot avatar model, a
  seeded deterministic draw, and a markup builder that turns a spec into the
  `<svg>` stack for a page. The builder holds no geometry and no colour — it
  names symbols in `_avatar-sprite.leaf` and tokens in `styles.css`, and two
  tests assert those names against both files in both directions. There is
  deliberately no seed-to-SVG shortcut: drawing is a one-time act whose result
  is stored, so that re-deriving per render cannot reshuffle every existing
  avatar when a slot gains an option. Not yet persisted or displayed.
