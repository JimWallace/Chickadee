### Fixed

- **The runner's downloads keep the session's timeouts.** Every download request set its own 5 s timeout, which overrode the session's 15 s idle interval and 10 min whole-transfer cap and could stop a large setup zip on a slow link from ever finishing. The request no longer sets one (#1793).
