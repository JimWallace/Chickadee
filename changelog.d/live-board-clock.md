### Fixed

- **The live board's 304 tests no longer flake.** The refresh reads its time from the app's clock (`LiveBoardClock`), which the tests pin, so two refreshes of an unchanged board share one 30-second ETag bucket. Production still reads the wall clock.
