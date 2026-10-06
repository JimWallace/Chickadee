### Changed

- **`APIUser.swift` holds only the user model.** The session authenticator, the request's course resolution and the two view-context types moved to their own files in `Middleware/`, `Helpers/` and `Utilities/`. `APITournamentMatch` moved out of `APITournamentRun.swift` into its own file. Only the code moved; nothing it does changed. (#2286)
