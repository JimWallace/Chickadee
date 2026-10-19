### Changed

- **Lab groups (slice 6a): lab groups from LEARN.** A synced group set now reads its groups from LEARN every ten minutes: the D2L Sections of the course offering, or one D2L group category. The sync keeps a renamed group, moves a student who changed group, removes a group that LEARN no longer lists, and writes through the same group store as the Groups tab. The old section sweep, which wrote a free-text name per enrollment, is replaced, and a course's configured section category becomes a synced set. A picker on the BrightSpace tab follows in slice 6b. See `docs/lab-groups.md`.

### Fixed

- The LEARN group-category and group readers now decode the bare JSON array that Valence returns. They expected a paging envelope, so they could not read a real response.
