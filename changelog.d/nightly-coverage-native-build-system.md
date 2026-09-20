### Fixed

- **The nightly clean-build canary measures coverage again on Swift 6.4.**
  The first nightly on the 6.4 toolchain failed at the lcov export (#1542):
  the default Swift Build engine emits one runner per test target and no
  `ChickadeePackageTests.xctest`. Repairing the path alone would not have
  helped, because that engine's coverage map holds only `Core`, `RunnerCore`
  and dependency C code, with `APIServer` and `Worker` absent, so the 60 %
  floor would have been measured over 55 source files instead of 635. The
  coverage run now passes `--build-system native`, the workaround the release
  build already carries, with the same removal condition recorded beside it.
