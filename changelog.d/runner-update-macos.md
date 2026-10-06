### Fixed

- **`deploy/chickadee-runner-update.sh` runs on macOS with Docker Desktop.** It used `mapfile` (bash 4), `flock` and `python3`, which a Mac does not have, so a cron job there would never update the runner. It now reads the JSON with `grep` and `sed`, takes its lock with `mkdir` (a lock whose owner is no longer alive is taken over), and adds the Docker Desktop and Homebrew directories to `PATH`. The deploy README gives the macOS cron line.
