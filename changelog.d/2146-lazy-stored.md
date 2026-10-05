### Changed

- **The last two hand-rolled get-or-create accessors in Services use `lazyStored` (#2146).** `Application.sweepLeaseHolderID` and the `serverStartedAt` getter now go through the one helper in `ApplicationLazyStorage.swift`, as every sweep monitor already does. No behaviour change.
