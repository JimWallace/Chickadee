### Fixed

- **One key-set fetch per LTI platform at a time.** Concurrent launches that miss the platform key cache now join the fetch already in flight, and a launch that fails after another launch fetched again uses the new keys. Before, a class that opened a link together sent one JWKS request per student. (#2309)
