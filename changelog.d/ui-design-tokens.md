### Changed

- **UI design tokens + enforcement.** The stylesheet now carries named type
  (`--text-2xs`…`--text-2xl`) and radius (`--radius-sm|md|lg|full`) scales, and
  every `font-size` / `border-radius` in `styles.css` and page `<style>` blocks
  routes through them — collapsing 26 accumulated font sizes and 18 radii onto
  8 + 4 steps (all shifts ≤ ~1px). Raw hex colours are now allowed only as
  palette `--token:` declarations; the off-palette stragglers (nav teals,
  primary-button hover, Bootstrap-green flash banners that ignored dark mode)
  were folded into the palette, and the previously *unstyled* `.flash` banner
  markup on the BrightSpace admin page got a real global component
  (`.flash-success/-error/-neutral` with dark-mode-aware semantic tokens).
  All of it is locked in by a new `scripts/check-design-tokens.sh` guard wired
  into `check-styles.sh` (CI `format-lint`), and the principles are written
  down in `docs/ui-design.md`.
