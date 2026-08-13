### Changed

- **The UI migration queue's page-local duplicates are converted.** The
  brightspace pages' `.bs-*` shared-concept classes, the storage/activity
  toolbar variants, the two history-page subtitle families, and
  `course-student-submissions`' popover all move onto the global component
  vocabulary (new: `.titlebar-subtitle`, `.popover-panel`); the Test Editor
  modal and the renderer/inputs editors drop their JS-written styling for
  class toggles (new: `.editor-modal-*`, `.editor-stack`, `.input-expression`
  and friends), so the per-student expression cue now adapts to dark mode via
  the palette. The page-style ratchet drops 913 → 811 lines and the
  JS-styling ratchet 122 → 100.
