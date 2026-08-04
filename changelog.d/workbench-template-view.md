### Added

- **The workbench can switch between a notebook's template and its rendering.**
  On an assignment whose notebook carries `{{placeholders}}`, the notebook pane
  gains a Template / With values control beside the Assignment / Solution tabs,
  so an author can compare what they wrote against what a student sees without
  leaving the page. The control is rendered per file and only where the two
  readings actually differ — on a notebook without placeholders they are
  byte-identical, and switching would be a kernel reboot for no change.

  Pane URLs now always carry an explicit `view=`. The server defaults staff to
  the template on a personalized notebook, so omitting it made the "Assignment"
  tab mean the template on one assignment and the rendering on another.

### Changed

- **The workbench holds one notebook document, not one per destination.** The
  tabs and the view switch repoint a single iframe. Previously each notebook got
  its own live iframe so switching was instant; with the view axis that would
  have been up to four simultaneous Pyodide kernels and an eviction policy to
  bound them — a lot of machinery for a secondary interaction. The workbench
  exists to put the edit page and *a* notebook on screen together, which holds
  with one. The accepted cost: switching notebooks re-boots the kernel.

  The browser check now asserts the iframe count directly, so reintroducing a
  frame per destination fails rather than passing quietly.
