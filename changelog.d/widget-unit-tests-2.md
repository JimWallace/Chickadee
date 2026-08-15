### Added

- **The four remaining untested authoring widgets have unit tests** — 43 tests
  across `support-files.js`, `section-items-dnd.js`, `section-inputs-editor.js`
  and `test-editor-modal.js`, which between them upload course data, order the
  dashboard, save per-section inputs and author every test. None of it was
  visible to an existing gate: the render tests never run page JS, and the
  visual harness captures none of these surfaces.

  What they pin is the part that fails silently rather than loudly:

  - an upload posts `tier: "support", isTest: false` — get that wrong and the
    file is stored as a **test** and starts being graded — and a batch that
    fails partway must not report success;
  - a drag that ends where it started posts **nothing**, a within-section
    reorder posts the whole mixed tbody (assignments *and* content items, or
    the omitted type's numbering comes out wrong), and the two types use
    different move endpoints;
  - the page-level flush covers **every** section-inputs form, since a missed
    one is an author's edit dropped behind a successful-looking save, and a
    rejected save must not tell the workbench pane its values are fresh;
  - the test-editor shell populates from the edit payload rather than the
    hidden dropdown's leftover value (the regression that made editing a check
    or script open a blank form), and tears the previous renderer down — a
    CodeMirror instance or kernel worker — on both close and mode switch.
