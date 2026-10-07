### Fixed

- **Three more process-wide singletons are created under the application lock.** The client-diagnostics rate limiter, the worker claim queue and the diagnostics service each spelled get-or-create by hand, so two first accesses at the same time could create two of them. They now use `lazyStored`, like every other store. (#2457)
