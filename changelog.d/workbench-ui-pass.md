### Fixed

- **Collapsing the workbench editor now actually gives the notebook the window.**
  Hiding the edit pane removed it from the grid without re-declaring the
  columns, so the notebook landed in the content-sized column and shrank to
  roughly 300px — narrow enough that the embedded notebook page rendered its
  "Open on a larger screen" notice. Collapsing the editor to see more of the
  notebook showed none of it. Found by screenshotting the real page; the
  collapse unit tests were correct and could not see it, so the browser check
  now asserts the rendered width.

- **The workbench no longer shows two template/values controls.** The embedded
  notebook page rendered its own view-toggle link beside the workbench's, and
  that link carries no `embedded=1` — following it would have loaded the fully
  chromed page inside the pane. The page's own toggle is suppressed when it is
  a workbench pane; the workbench's control is the one that works there.
