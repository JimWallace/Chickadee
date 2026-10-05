### Fixed

- **Adding a script carries every field of the entry (#2124).** `updateManifestAddingScript` rebuilt the new entry field by field to set its position and left out `failureDetail`. One `ConfiguredSuiteEntry` initializer now copies the entry and sets the position, so a field added later cannot be dropped by a copy that names fields. A new test adds a script with every field set and reads each one back.
