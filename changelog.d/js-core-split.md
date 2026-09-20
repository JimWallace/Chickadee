### Added

- **Unit tests for five page scripts that had none.** The achievements
  editor, the notebook preflight, the two test-editor body renderers and the
  starter-test generator kept their decisions inline among element lookups,
  where the node test harness could not reach them. Each now has a DOM-free
  `-core.js` module (the `inputs-editor-core.js` pattern) loaded before its
  wiring file, with tests pinning the rules whose failure was silent on the
  page: a deleted section ref serialising as the whole suite, a class-wide
  signal surviving into a per-student badge, a disabled check field restoring
  a stored value, an Octave author offered Python templates, and a generate
  step reporting files it never wrote. The page scripts keep only the DOM,
  the file readers and the fetches.
