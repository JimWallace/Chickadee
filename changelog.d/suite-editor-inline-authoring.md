### Changed

- **Test-suite editor: author tests inline.** The instructor assignment editor
  replaces the in-modal test-type picker with a **"+ Add Test" dropdown** on
  each section, and pattern families and notebook checks are now edited
  **inline in expandable rows** (Save/Cancel in place) rather than in a modal —
  only custom scripts still open the code editor. Notebook-check rows also gained
  inline tier/points editing. One editor is open at a time; a debounced suite
  save can't wipe an open editor (the table defers its re-render until the editor
  closes). MCP `create_pattern_family` / `update_pattern_family` descriptions and
  the server instructions now note the auto-generated existence guard that
  function-calling families carry.
