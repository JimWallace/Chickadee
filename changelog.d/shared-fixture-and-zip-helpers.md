### Changed

- **Shared enrollment, user and zip fixtures in the API tests.** `makeTestEnrollment` takes an optional per-course `role`, and the private copies of it, of `makeTestUser`, of `makeTestCourse`, of `writeSetupZip` and the pass-through `arMakeZip`, `ahMakeZip` and `makeZipAt` aliases of `writeZipFixture` are gone, so each fixture has one definition.
