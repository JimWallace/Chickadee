### Removed

- **Seven overloads that only tests called.** The `testSetupID:` forms of `recordActivityMatch`, `awardClassBadgesFor100Percent`, `recordClassItemCoverage` and `recordLeaderboardEntry`, `LTIGradeSyncQueue.queue(submissionID:testSetupID:on:)`, `CompositeSlots.slot(assignmentID:...)` and the section-less `AuthoredSuiteItem.family(id:)` are gone. The tests now call the forms that production uses (#3234).
