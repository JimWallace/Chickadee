### Security

- **Swift dependencies brought current.** Dependabot has not opened a Swift
  PR since the move to `swift-tools-version:6.4`, because its Swift toolchain
  is 6.3.1 and refuses the manifest. This updates the root graph by hand:
  Vapor 4.122.3, swift-nio-ssl 2.37.6, swift-certificates 1.21.1, jwt 5.2.0,
  jwt-kit 5.8.0, async-http-client 1.37.0, postgres-nio 1.33.2 and twelve
  other patch or minor releases. The swift-subprocess fork pin is unchanged.

### Fixed

- **Dependabot pip updates run again.** `Tools/jupyterlite/requirements.txt`
  named the Chickadee extension by a local path, and every weekly pip run
  aborted with `path_dependencies_not_reachable`. `scripts/setup-jupyterlite.sh`
  now installs the extension itself, after the requirements file.
