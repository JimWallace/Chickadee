### Added

- **Live-session controls for class activities.** An activity can now run to a
  clock: a session window with an opening time, a closing time or both.
  Submissions outside it are refused, with a message saying which side of the
  window the student is on; course staff are never gated, so an instructor can
  run and demonstrate the session. The window is separate from the assignment's
  due date, so a slip day cannot extend a live contest and a contest's end
  cannot close an assignment.

  The leaderboard counts down to the next boundary and refreshes itself while
  the session is open, stopping when it ends. Set the window on the assignment
  edit page's Activity section or through MCP `set_activity`
  (`opensAt` / `closesAt`, ISO-8601).

  This closes slice 8, the last of the class-activities plan (#1508).
