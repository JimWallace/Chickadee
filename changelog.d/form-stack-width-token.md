### Changed

- **`--form-stack-width` is a design decision, not a per-page dial.** It was
  the same defect `--filter-width` had, one generation earlier: declared with a
  `480px` fallback in the stylesheet and then assigned inline at `60rem` on the
  instructor MCP tab and `32rem` on slip days — 2rem off the default, for no
  reason anyone recorded. The token is now declared once in `:root` (30rem),
  the one form that genuinely wants the room (an authoring-guide textarea)
  takes a named `.form-stack--wide` modifier, and slip days uses the default.

  The `check-styles.sh` guard generalized with it: an inline custom property in
  a template may now only carry a value that varies per **datum** (`--bar-h`, a
  chart bar's height from the row being rendered). A width that differs because
  someone preferred it there is a design decision and belongs in `styles.css`.
