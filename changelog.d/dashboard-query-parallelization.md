### Changed

- **Dashboard queries parallelized.** The student dashboard's independent DB
  reads now run concurrently via `async let` (extensions, prior engagement,
  course sections; grade overrides + submissions; results + achievement
  lookups), cutting the handler's sequential round trips roughly in half.
  The engagement/extension/section loaders moved to
  `WebRoutes+IndexLoading.swift`. No behaviour change — same queries, same
  results, fewer back-to-back waits.
