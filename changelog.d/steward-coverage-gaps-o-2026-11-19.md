### Changed

- **Tests for the BrightSpace API client.** New suites drive the real D2L client against a scripted HTTP client. They cover the API version pin, cache and fallback, the one clock-skew retry after a timestamp error, and how each read and write maps a refusal to its own error: the user lookup, whoami, the org unit and grade item reads, the grade push and clear, the paged classlist and the group readers. No product code changed.
