### Changed

- **Animated, easier-to-scan inline editors on the assignment edit page.** The
  inline "accordion" editors (pattern families / notebook checks in the suite
  editor, and the achievements editor) now expand and collapse with a smooth
  height animation instead of popping open. The open editor is tied to its row
  with a left accent bar and a rotating disclosure caret, rows highlight on
  hover, and per-test separators are firmer so individual tests are easier to
  tell apart. The animation is honoured uniformly through a single shared
  helper (`ChickadeeUI.accordion`) and respects `prefers-reduced-motion`.
