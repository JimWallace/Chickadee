### Fixed

- **The GitHub compliance documents name the real routes and hosts.** The data-flow inventory and the trust-boundary document named routes that do not exist and left out `codeload.github.com`, the host the tarball download is redirected to, so an operator who allowlisted the listed hosts would break GitHub submission.
