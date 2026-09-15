### Fixed

- **The runner's test-setup cache key is stable again (#1526).** It hashed a
  manifest encoding whose key order is not contractual, so the same job could
  hash two ways and the on-disk LRU cache could not reliably hit — every test
  setup re-downloaded and re-extracted, with nothing in the logs to say why. The
  key now hashes a canonical encoding, which is the convention every other
  hashing path in the codebase already followed.
