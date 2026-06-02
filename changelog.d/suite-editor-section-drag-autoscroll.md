### Fixed

- **Suite editor: drag whole test blocks into new sections, and auto-scroll
  while dragging.** Dropping a test onto a freshly created (empty) section's
  drop row now moves the entire connected dependency group into that section
  with its prerequisites/dependents intact, instead of stranding the children
  and silently wiping the parent's dependencies. The drop row in an empty
  section is now labelled "Drop tests here" (it keeps the "remove dependency"
  meaning only inside a populated section). The suite list also auto-scrolls
  the page when a drag nears the top or bottom of the viewport, so long suites
  taller than one screen can be reorganised without manually scrolling.
