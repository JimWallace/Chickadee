### Removed

- **Unused `data-runner-id` attribute on the admin runner page.** No script
  reads it after the runner poller moved onto `table-poll.js` (#3029). A test
  comment that still named the deleted `account-export.js` now names the
  account page's polled region.
