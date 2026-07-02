### Changed

- **UI design tokens + enforcement.** The stylesheet now carries named type
  (`--text-2xs`…`--text-2xl`) and radius (`--radius-sm|md|lg|full`) scales, and
  every `font-size` / `border-radius` in `styles.css` and page `<style>` blocks
  routes through them — collapsing 26 accumulated font sizes and 18 radii onto
  8 + 4 steps (all shifts ≤ ~1px). Raw colour literals (`#hex`, `rgb(a)`,
  `hsl(a)`) are now allowed only as palette `--token:` declarations; the
  off-palette stragglers (nav teals and white-alpha foregrounds,
  primary-button hover, Bootstrap-green flash banners that ignored dark mode,
  raw-rgba MCP banners and roster flags) were folded into the palette, and the
  previously *unstyled* `.flash` banner markup on the BrightSpace admin page
  got a real global component (`.flash-success/-error/-neutral` with
  dark-mode-aware semantic tokens). Pop-out menus, dropdowns, and floating
  panels share one `--shadow-pop` elevation token (now actually visible in
  dark mode), and spacing sits on a shrink-only 26-step lattice (converged
  from 33; oddballs like `.375rem`/`.28rem` folded onto neighbours). All of it
  is locked in by a new `scripts/check-design-tokens.sh` guard wired into
  `check-styles.sh` (CI `format-lint`), and the principles are written down in
  `docs/ui-design.md`.
