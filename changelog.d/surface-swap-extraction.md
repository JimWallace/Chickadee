### Changed

- **The workbench surface swappers moved out of `chickadee-ui.js` into
  `Public/surface-swap.js`** as `ChickadeeSurfaceSwap`, completing the
  decomposition of a module that had grown to eighteen unrelated functions
  behind one name. This is the largest of the three concerns and the one with
  the most rules of its own: a fetch, a parse, a node-identity discipline, and
  the only place in the frontend that deliberately turns markup into running
  code.

  No call site changes: `ChickadeeUI.refreshEditSurface` and
  `.refreshNotebookSurface` remain the call surface and resolve at call time.
  One of those callers is `inplace-forms.js`, which `base.leaf` loads on every
  page and which refreshes after every successful in-place save — so unlike the
  other two splits this one could never have been page-scoped, and it is loaded
  from `base.leaf` beside `chickadee-ui.js`.

### Added

- **The pane swap has a real-enough DOM harness** — 15 tests covering two rules
  nothing was exercising. The existing suite covers the swap's outer decisions
  (swap vs. reload, which URL, the reload fallback); its stub reports no scripts
  and no carried element, so both of these failed silently:

  - `runInlineScripts` re-creates inline `<script>` elements, because one
    inserted by parsing HTML does not run — a deliberate platform rule. Its
    exclusions are now pinned: a `src=` script is left alone (re-creating it
    would re-run the module's IIFE and double-bind every listener it installs),
    and a JSON seed island is data, left untouched and still findable by id with
    its type intact.
  - `keepElement` carries the notebook frame across the swap by object identity.
    34 closures captured that element; rebuilding it leaves every one of them on
    a detached node while the page still looks right.

  Each assertion was checked against a deliberately broken source: dropping the
  type guard, widening the selector to include `src=`, skipping the carried-over
  replace, dropping the scroll restore, and turning any of the three call-time
  re-exports into an eager capture each turn exactly the expected tests red.
