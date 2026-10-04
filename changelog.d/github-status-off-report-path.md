### Fixed

- **A slow GitHub no longer holds the runner's result report, and logout revocation has a real time limit.** The commit-status post and the IdP token revocation each raced their work against a timer. A task group waits for all its children, and a pending HTTP call ignores cancellation, so the timer ended nothing early. The status post now runs as owned background work after the report's response, so the runner never waits on GitHub; each GitHub call keeps its 30-second request timeout. Each revocation call now has a 5-second request timeout (#1925).
