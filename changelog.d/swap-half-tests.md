### Added

- **The workbench pane swap has a real-enough DOM harness** — 14 tests covering
  the two rules nothing was exercising. The existing suite covers the swap's
  outer decisions (swap vs. reload, which URL, the reload fallback); its stub
  reports no scripts and no carried element, so two of the swap's rules had no
  coverage at all, and both fail silently:

  - `runInlineScripts` is the one place in the frontend that turns markup into
    running code on purpose. A `<script>` inserted by parsing HTML does not run
    — a deliberate platform rule — so the swap re-creates the element to get the
    page's wiring back. Its exclusions are now pinned: a `src=` script is left
    alone (re-creating it would re-run the module's IIFE and double-bind every
    listener), and a JSON seed island is data, left untouched and still findable
    by id with its type intact.
  - `keepElement` carries the notebook frame across the swap by object
    identity. 34 closures captured that element; rebuilding it leaves every one
    of them on a detached node while the page still looks right. The tests use
    nodes with identity and a fragment that actually moves its children, since a
    stub returning fresh objects would make the whole file vacuous.

  Each assertion was checked against a deliberately broken source — dropping the
  type guard, widening the selector to include `src=`, skipping the carried-over
  replace, and dropping the scroll restore each turn exactly the expected tests
  red.
