### Fixed

- **Auto-compute fills a pattern-family case's Expected value again.** The editor asked the language seed for the in-page worker through an accessor that was never added, so every auto-compute threw an error and the cell stayed on "computing…" for every language. The seed reader now provides it, and Python, R, Lua and Octave compute in the page again (#1956).
