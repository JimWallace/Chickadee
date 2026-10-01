### Changed

- **One writer for secret files.** `.worker-secret`, `.mcp-signing-key`, `.lti-tool-key` and `.github-app-secrets` are all created with mode 0600 in one call through `SecretFile`. Three of the four writers used to write the file first and restrict it second, leaving a moment in which the secret was readable by other local users (#1649).
