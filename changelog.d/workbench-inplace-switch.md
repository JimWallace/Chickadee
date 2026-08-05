### Changed

- **Switching notebooks in the workbench no longer reloads the page.** Opening
  the solution, or toggling between the authored template and the rendered
  values, swaps the notebook half in place instead of navigating. The Pyodide
  kernel still restarts — it belongs to whichever notebook is open — but the
  edit half is no longer rebuilt with it, so assignment details typed and not
  yet saved survive the switch. The address bar still moves, so a reload lands
  on the same notebook and Back returns to the previous one.

### Fixed

- **The workbench's view control showed the wrong view as selected.** "With
  values" was marked as the active choice regardless of what was open. Course
  staff are defaulted to the *template* on a notebook carrying placeholders, so
  the control mislabelled itself on exactly the assignments it exists for.
