### Changed

- **`LTIToolKeyAuthority` no longer carries a test-only `verify`.** The deep-linking test now verifies the tool's response the way a platform does, with a key set built from the published JWK. The launch test that refuses a deep-linking request on the launch endpoint is named for what it checks (#1661).
