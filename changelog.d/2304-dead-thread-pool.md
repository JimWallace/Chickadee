### Removed

- **Unused thread-pool fields in two caches.** `ZipEntryListCache` and `NotebookBytesCache` no longer store a thread pool and an event-loop group that they never used, and their comments no longer describe the removed offload and zip lock. (#2304)
