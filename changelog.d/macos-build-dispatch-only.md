### Changed

- **macOS build is dispatch-only for now.** No GitHub-hosted image has the macOS 27 SDK that `Package.swift` requires, so the weekly `macos-build.yml` run could only fail. Its schedule and its weekly-digest row are removed until such an image exists; the workflow header says how to restore both.
