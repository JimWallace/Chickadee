### Changed

- **The server refuses to boot on a database from v0.4.200 or earlier.** The migration-namespace reconciler renamed such a database's history rows so that its migrations counted as applied. Since the consolidation rounds folded later migrations into their `Create*` files, that rename let the server start without the folded columns, and the first query on those models then failed. The server now stops at startup and names the problem. A database from a later release is not affected. (#2282)
