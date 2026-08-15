### Fixed

- **Dragging a row in the suite editor no longer re-decides the drop target on
  every frame.** `dragover` fires continuously while the pointer moves, and the
  handler treated each event as if nothing were known: it scanned the item list
  three times for rows it had already resolved — twice for the *dragged* row,
  whose identity is fixed for the whole gesture — cleared every drop indicator
  in the container with a full `querySelectorAll`, and read a row's bounding
  rect, forcing a synchronous reflow.

  It now resolves the dragged row once at `dragstart`, reuses the target row's
  lookup instead of scanning again for the same answer, and decides before it
  writes: if the drop target and its zone are what they were on the previous
  event — which is most events, since a pointer spends many frames over one row
  — it touches no DOM at all. Counted over a five-second drag at 60 fps with the
  pointer crossing twenty rows: **1,035 → 25 list scans, and 300 → 20 indicator
  clears and forced reflows.** Reflow-per-event is the shape that caused the
  post-boot editor freeze (`docs/browser-freeze-investigation.md`); it did not
  belong on this path either.

  No behaviour change. The same section drag path got the same treatment.

### Added

- **The suite editor's drop-zone decision is a pure, tested function**
  (`dropZoneFor`). It was inline in a 1,700-line file whose existing tests cover
  file classification and error extraction and nothing about the table — and
  nothing else gates it, since the render tests never run page JS and the visual
  harness captures no page that draws it.

  Ten tests pin the part that fails quietly: the middle band *adopts*, which
  writes a dependency edge, and each of its five refusals exists because the
  edge would be one the server cannot expand or the graph cannot hold — a
  cross-section token, a check at either end (checks are graph leaves), a target
  that already has a parent, or one that already has children. A wrong "yes"
  there does not look wrong on screen: the row lands, the suite saves, and a
  test's prerequisite is quietly not what the author drew.
