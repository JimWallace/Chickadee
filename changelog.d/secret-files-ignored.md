### Security

- **`.lti-tool-key` and `.github-app-secrets` are git-ignored.** Both are written to the working directory by default and were absent from `.gitignore`, so a developer running the server from a checkout could commit an App private key. A new guard reads the secret file names from `SecretFile.swift` and asserts each is ignored, with a fixture proving it fails (#1772).
