### Changed

- **The workbench is now the assignment editor.** The `/instructor` dashboard's
  Edit buttons open it, and its chrome has been cut back to what the panes do
  not already provide: no Assignment/Solution tab strip, no Hide-editor or
  Full-width-editor buttons, no repeated assignment title, and no Download in
  the notebook pane. The left pane already names the assignment, lists its
  files with links, and offers Edit for each.

- **One Save, in the top-right corner.** "Save & Validate" and "Save to
  assignment" were two buttons for what an author thinks of as one action.
  The single Save writes the open notebook and the assignment's details and
  re-validates.

  It deliberately does **not** close the assignment. The standalone edit page
  still does, unchanged — but the workbench is a live-edit surface, where the
  suite, families and notebook endpoints all already write without changing
  visibility, and closing on save there would pull a lab out from under the
  students sitting in it.

- **Clicking Edit in the Files table opens that notebook in the workbench's
  notebook pane.** Previously those links carried no `embedded=1`, so inside
  the workbench they navigated the *left* pane into a fully chromed notebook
  page and the assignment editor disappeared. They are still ordinary links on
  the standalone page.
