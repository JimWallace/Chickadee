### Fixed

- **The REST zip upload stores its manifest with the stable encoder.** It was the last production caller of the plain `JSONEncoder` on `ManifestCodec`, whose key order is not stable. That encoder is deleted, so a stored or hashed manifest can only go through `stableEncoder` (#1719).
