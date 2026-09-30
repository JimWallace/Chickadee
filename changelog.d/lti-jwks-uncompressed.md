### Fixed

- **Brightspace can read the LTI key set.** `GET /lti/jwks` is now sent uncompressed. The server answered a client that accepts `deflate` with zlib-wrapped deflate, and Brightspace reported "Keyset URL cannot be reached" when it registered the tool, although the request returned 200.
