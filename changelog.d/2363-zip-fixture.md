### Changed

- **Tests write fixture zips through one helper.** Thirteen suites carried a private `writeZip(at:entries:)`, and the shared `arMakeZip` and `ahMakeZip` were a fifteenth and sixteenth copy that called `zip` themselves. All of them now use `writeZipFixture(at:entries:)` in `ZipFixtureSupport.swift`, which also replaces an existing archive instead of adding to it. (#2363)
