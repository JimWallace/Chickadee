### Fixed

- **The workbench shell smoke check no longer races the toolbar insert (CI Family 9).** The check now waits for the inserted code cell to become active before it clicks the cell's editor. Before, the click could find the hidden editor of the old active markdown cell and wait on it for 30 s. The weekly flake tally also counts each red attempt, including one that a re-run hid, and no longer counts a run that a newer push cancelled.
