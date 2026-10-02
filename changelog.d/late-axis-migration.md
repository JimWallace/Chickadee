### Changed

- **The tuft and tilt fill is a one-time migration, not a rule on every avatar read.** A bird stored before those axes existed was filled lazily on its next account-page load, behind a probe `AvatarStore.ensureSpec` ran on every read. `FillLateAvatarAxes` fills the missing axes of every stored bird once, the store returns a stored bird as stored, and the lazy-fill tests are replaced by a migration test (#1762).
