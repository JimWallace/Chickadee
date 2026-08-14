### Changed

- **Destructive actions ask in a real dialog instead of the browser's.**
  `ChickadeeUI.confirmAction` was `window.confirm`, with a comment saying it
  existed so the native dialog could be replaced in one place; this is that
  replacement. It covers all 41 destructive confirmations — 36 `data-confirm`
  attributes across 18 templates plus 5 direct callers (unenroll a student,
  delete a course section, delete a test script, delete a pattern family,
  remove a support file). The native dialog was the last piece of UI outside
  the design system: unthemed in dark mode, unstyleable, drawn by the browser
  chrome rather than the page, and invisible to the axe scan. It is the sibling
  of the native alerting call the S9 slice removed, and it outlived that slice
  only because nobody had written the dialog.

  The new one is a `role="alertdialog"` on the shared modal shape: Cancel takes
  focus (so an accidental Enter is the safe answer), Escape and a scrim click
  cancel, Tab cycles inside it, and focus returns to whatever had it. The
  message is set as text, never parsed as markup.

  **The one thing callers must know: it returns a promise.** A real dialog
  cannot block the event loop the way the native one did. `data-confirm` is
  unaffected — the seam in `app.js` now cancels the interaction, asks, and
  replays it (a click, or `requestSubmit` with the original submitter) if the
  answer is yes — and the five direct callers await it.

  `check-styles.sh` drops the exemption it carried for the native call, so
  that rule is now absolute like the alerting ratchets beside it.

### Added

- **The confirmation has unit tests** — the dialog's accessibility behaviour
  and, separately, the `data-confirm` seam's replay in both directions: a
  destructive action must not fire without asking, and must not be silently
  dropped after the user says yes.
