### Fixed

- **Borders drawn with `--gray-300` are dark in dark mode.** The token had no dark value, so row menus, extension panels and closed-assignment strips showed near-white lines on a dark page. `scripts/check-css-vars.sh` now fails when a grey step has no value in either dark block. (#2401)
