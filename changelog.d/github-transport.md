### Fixed

- **Every GitHub call records whether GitHub answered.** Only the repository calls recorded reachability, so a GitHub outage during account linking, course binding or App registration did not reach the egress alert. All three now send through one `GitHubTransport`, which sets GitHub's headers, applies the 30-second timeout and records each send (#1769).
