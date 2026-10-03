### Changed

- **Grade fields and audit metadata are decoded once, with `Decodable`.** Four functions read a result's four grade fields from the collection JSON, each with its own `JSONSerialization` pass, and the legacy grade path parsed one blob three times. `CollectionGradeFields` now decodes the blob once, field by field, and `APIResult`'s column accessors use the same formulas. Three private decoders of `audit_log.metadata` became one `metadataDictionary` accessor on `APIAuditLogEntry` (#1931).
