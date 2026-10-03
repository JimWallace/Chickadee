### Changed

- **One retry for a transient SQLite lock.** Worker claims and the attempt-number transaction had two retry loops with two different "is this a lock?" classifiers, so a lock one of them retried could fail at once in the other. `withTransientDatabaseLockRetry` (in `Helpers/TransientDatabaseLockRetry.swift`) is now the only one: each caller keeps its own attempt count and backoff, and the classifier accepts every lock either old one did (#1926).
