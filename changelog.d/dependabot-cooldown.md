### Security

- **Dependabot waits before it offers a release.** Every Dependabot entry now has a `cooldown`: a new version is offered when it is 3 days old, and a new major version when it is 14 days old. Dependency updates merge and deploy with no person involved, and most compromised releases are withdrawn within that time. Security updates are not delayed.
