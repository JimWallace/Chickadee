### Fixed

- **Removing the GitHub App drops its cached installation tokens.** An admin who removed an App, for example after a key leak, and registered another kept acting on GitHub with the old App's tokens for up to an hour. Removal now clears the cache, and so does a new registration.
