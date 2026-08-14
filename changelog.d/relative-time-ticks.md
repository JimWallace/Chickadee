### Fixed

- **Relative timestamps keep up with the clock instead of freezing at page
  load.** `relative-time.js` applied exactly once per load, so a timestamp was
  live only where something else happened to repaint it — the three tables
  `table-poll.js` refreshes every five seconds. Everywhere else (the runner
  dashboard, the MCP agent lists, alerts, the activity log) "2 minutes ago"
  meant "2 minutes before you opened this tab", for as long as the tab stayed
  open. It now ticks at a cadence set by the freshest stamp on the page — 15 s
  while something is seconds old, a minute while something is minutes old, five
  minutes otherwise — writing text only when the rendered string actually
  changes, so a quiet page mutates no DOM. Ticking stops while the tab is
  hidden and catches up on return, so a tab left open overnight re-renders when
  you come back to it rather than one interval later.

### Added

- **`relative-time.js` has unit tests.** It is loaded on every page and had
  none — it also had no Node export block, which is part of why. The suite
  pins the cadence, the re-arm, the write-only-on-change rule, the hidden-tab
  behaviour, and the formatting the six drifted copies it replaced disagreed
  about.
