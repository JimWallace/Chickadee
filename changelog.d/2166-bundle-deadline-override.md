### Fixed

- **The course bundle carries the deadline override (#2166).** An assignment kept open past its due date imported without the override, so the next deadline sweep closed it. `BundledAssignment` now has an optional `deadlineOverrideActive`, written on export and applied on import; a bundle written before it was carried imports as before.
