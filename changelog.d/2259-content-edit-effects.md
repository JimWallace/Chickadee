### Fixed

- **A web script or support-file edit re-validates the assignment on the server.** The page used to send a follow-up suite request after some edits, but not after a support-file delete, so that delete left a stale validation status while a test that imported the file failed for every student. The web script routes and the MCP tools now share one post-edit step, and `WebContentEditCoverageTests` classifies every web write handler (#2259).
