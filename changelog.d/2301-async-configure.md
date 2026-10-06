### Fixed

- **Server boot no longer blocks a Swift concurrency thread.** `configure` and `bootstrapAppServices` are now `async`. The migrations and the stored BrightSpace credential are awaited, not resolved with `.wait()`. Before, boot blocked a thread of the cooperative pool while it waited for work that needed a thread of the same pool, so on a host with one core it could hang. (#2301)
