### Fixed

- **A new runner's first polls no longer fail with HTTP 500.** A runner polls
  from every job slot at once, so its first check-ins each found no profile row
  and each tried to insert one; all but one hit the unique constraint on
  `runner_profiles.runner_id`. A check-in that loses the race now reads the
  winner's row and updates it.
