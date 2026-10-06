### Fixed

- **The hourly LTI reaper uses its index.** Its delete filtered `expires_at < now OR consumed`, and no index covers `consumed`, so each sweep scanned both tables. The reaper now runs two deletes per table, and each is a range on the `expires_at` index. Which rows it removes does not change. (#2279)
