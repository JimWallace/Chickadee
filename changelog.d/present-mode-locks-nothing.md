### Fixed

- **Leaderboard Present mode locks no handle.** The projected page reused the nameless rendering through `isStaff: false`, and that flag also decided whose view locks handles, so a staff member opening Present mode to check it spent every student's one handle change. The three board builders now take an explicit `lockingFor:`, and the Present page passes none (#1757).
