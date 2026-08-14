### Changed

- **One confirmation seam (audit S5).** Every "are you sure?" prompt in the web
  UI now declares its question in markup and runs through a single handler,
  replacing 49 hand-written inline confirmation handlers. Cancelling a
  destructive action now also cancels whatever the button sits inside (row
  navigation, popovers) rather than only the action itself, and two actions
  that had drifted into two different wordings — resetting a student's
  notebook, and removing a support file — now say the same thing everywhere.
