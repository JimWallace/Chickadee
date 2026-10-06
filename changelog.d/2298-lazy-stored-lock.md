### Fixed

- **Concurrent first accesses to application storage keep every entry.** Vapor reads and writes the whole `Application.storage` struct under separate locks. Two first accesses to different `lazyStored` keys at the same time could each write back a struct without the other entry, so a sweep monitor could be lost and outlive shutdown. `lazyStored` now checks and stores under the application lock, and builds the value outside it. (#2298)
