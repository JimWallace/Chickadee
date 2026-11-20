### Fixed

- **The Deployment page no longer invites the same request twice.** A request waits for the deploy daemon's next poll, up to five minutes, and until then the page showed the old mode, so on 2026-11-18 the same mode change was sent four times. Now a waiting mode change is shown checked, with a note that the deployer applies it at its next poll; a waiting approval shows as approved; a mode, pause or resume that repeats the last waiting request of its kind, or an approval already waiting, is not written again; and saving the mode already in force sends nothing.
