### Fixed

- **Predeploy snapshots no longer fill the disk.** The deployer takes a full snapshot (database dump and every submission) before each release, and `snapshot.sh` deleted snapshots only after 7 days. With up to 25 releases a day, the copies filled the production disk, Postgres stopped, and login and both MCP surfaces failed. `snapshot.sh` now keeps only the newest 3 predeploy snapshots, and it prunes before it needs the database, so a run on a full disk still frees space. The deployer also removes the runner image that a runner refresh replaces.
