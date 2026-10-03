### Changed

- **Fifteen column and index migrations are folded into their `Create*` files** (#1806). This is the fourth consolidation round. A fresh database gets the same schema in fewer steps. A database that already ran the folded migrations is not changed: Fluent records each migration by name and ignores names that are no longer registered. `AddLTIGradeSyncFailureReasonColumn` stays separate because it fills in existing rows.
