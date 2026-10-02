### Changed

- **The runner test-setup cache key no longer hashes the test-setup id, and an unencodable manifest is a forced miss.** The id is the key's verbatim prefix, so hashing it too changed the digest's value but never which jobs collide; the append, its boundary test and its stale equivalent-mutant entry (which still quoted an encoder renamed in #1679) are gone, at the cost of one cache miss per entry after the upgrade. A manifest that fails to encode used to key on id and URL alone, which is a collision rather than a miss; it keys on a fresh digest now (#1790).
