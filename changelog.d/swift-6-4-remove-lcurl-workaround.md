### Fixed

- **Removed an unnecessary `-lcurl` from the runner's release build.** v0.5.203
  added `-Xlinker -lcurl` to `chickadee-runner`, on the belief that Swift 6.4
  drops libcurl from the static link line the way it drops
  `lib_FoundationICU.a`. That was a misdiagnosis: the curl link errors came
  from running the Swift Build engine and then `--build-system native` into
  the same `.build` directory, and a clean build of the runner on 6.4 links
  without the flag. A minimal reproducer confirms it — a package that only
  formats a number reproduces the ICU failure, while one that drives
  URLSession does not reproduce any curl failure on either engine.
  The flag was harmless, since curl is a genuine transitive dependency, but
  the comments beside it asserted a Swift 6.4 defect that does not exist.

  `--build-system native` stays. That workaround is real, reproducible in
  about twenty lines, and still needed.
