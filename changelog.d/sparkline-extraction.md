### Changed

- **The sparkline renderer moved out of `chickadee-ui.js` into
  `Public/sparkline.js`.** That module is loaded from `base.leaf` on every page
  and had accumulated eighteen unrelated functions behind one name — escaping,
  CSRF, a fetch wrapper, a status line, a modal, a chart renderer, an accordion,
  two surface swappers. Drawing a chart is not a shared utility in the sense
  that escaping a string is.

  No call site changes: `ChickadeeUI.renderSparkline` remains the call surface
  and delegates to `ChickadeeSparkline.render`, looked up at call time so the
  two files' load order does not matter. Repointing callers is a later, separate
  step, kept out of the move so a move cannot hide a behaviour change.

  The renderer picks up its first ten tests. Nine cover behaviour — the one
  worth reading is that "no data" and "zero" must not draw alike. The tenth
  exists for a structural reason: this file assigns to `innerHTML`, so it now
  owns its escape rather than borrowing ChickadeeUI's through a global. The
  first draft of the extraction borrowed it and silently degraded to a
  **non-escaping** fallback when that global was absent, which CodeQL caught —
  correctly, since a scanner cannot follow a sanitizer through a global property
  any more than a reader can. Owning it costs a second copy of a function the
  June 2026 audit deduplicated, so the test pins the copy against the original
  character for character.
