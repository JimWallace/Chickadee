### Fixed

- **Snapshots carry the signing keys.** `scripts/snapshot.sh` and `scripts/restore.sh` predated the per-integration key files, so a restore to a fresh host lost the LTI tool key, the MCP signing key and the GitHub App secrets, and every LTI launch then failed signature verification. The three files now ride the snapshot, and `--regenerate-secrets` also drops the two regenerable keys (#1648).
