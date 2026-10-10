### Changed

- **Spike: the admin user page renders through Elementary.** `GET /admin/users/:userID` now renders with Elementary, type-safe HTML views written in Swift, instead of Leaf. The markup matches the Leaf output. The findings and the decision points are in `docs/elementary-spike.md`.

### Fixed

- **The admin user page shows a refused enrollment.** Adding a user to a missing or archived course now shows "That course does not exist or is archived." Before, the page reloaded with no message.
