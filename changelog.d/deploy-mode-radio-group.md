### Changed

- **The deploy mode is a radio group on the admin Deployment page.** It was a list of the three modes with a "Switch" button on each row except the current one, which a badge marked. Now the current mode is the checked radio, each mode has its one-line summary, the default says "(default)" in its name, and one "Save mode" button asks before it sends the request.

### Fixed

- **The neutral `.tier` badge shows in dark mode.** Its fill was `--gray-100`, which dark mode sets to the page surface, so "Current", "Approved" and every other bare badge read as loose words. It now uses `--badge-neutral-bg`, one step up in dark mode and unchanged in light.
