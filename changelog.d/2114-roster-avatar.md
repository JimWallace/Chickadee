### Changed

- **One helper builds the roster avatar cell (#2114).** Six pages each loaded a person's avatar spec and then built the same roster-sized decorative presentation. `AvatarStore.rosterAvatar(for:isStaff:on:)` does that once, and each site is one line. The leaderboard pages, which choose a labelled presentation, are unchanged.
