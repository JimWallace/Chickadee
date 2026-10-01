### Changed

- **Org-unit binding and auto-map are a service; the manual sync triggers sit beside the sweep.** `BrightSpaceCourseBinding` binds or clears a course's LEARN org unit and maps assignments to grade items by name; `requeueErroredGradePushes` and `launchBackgroundBrightSpaceSweep` moved into `BrightSpaceGradeSyncService` next to `requeueForImmediateSync`. The BrightSpace route extension now holds route handlers only. Slice 3 of #1654.
