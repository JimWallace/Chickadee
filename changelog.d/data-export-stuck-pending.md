### Fixed

- **Personal-data export stuck "in progress" forever.** Export generation
  runs in a background task inside the server process, so a restart mid-run
  (e.g. a blue-green redeploy) orphaned the request in the `pending` state:
  the account page's status poll never resolved and the user was never told
  their export was ready or had failed. A leader-leased sweep now flips a
  `pending` export that has outlived the staleness window (15 min) to
  `failed`, so the poll resolves and the "request data export" button
  reappears for a fresh attempt.
