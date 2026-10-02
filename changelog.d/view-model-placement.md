### Changed

- **View models live with the other contexts, or stay private to their one reader.** The sixteen leaderboard contexts and the four slip-day contexts that sat in their route files now sit in `LeaderboardContexts.swift` and `SlipDayContexts.swift` beside the other context files. The six contexts with one reader (the submission diff, the Activity tab, the LTI grades page and the admin BrightSpace page) are private to that file. Placement only; no behaviour changed (#1716).
