### Fixed

- **A student who renames their GitHub account can still submit.** The installation was found by the login stored at link time, so after a rename the submit page offered *Install on GitHub* for an App that was already installed. A miss now falls back to the App's own installation list, searched by the account's numeric ID, and the stored login is updated.
