### Fixed

- **A browser result is no longer lost to a held SQLite write lock.** On SQLite, the transaction that numbers a new submission read the highest attempt number and then wrote. A transaction that has read cannot wait for the write lock, so when another connection held it, the insert failed at once and the result POST returned HTTP 500. The transaction now opens with `BEGIN IMMEDIATE`, so it waits for the lock before it reads. Postgres was not affected (#1919).
