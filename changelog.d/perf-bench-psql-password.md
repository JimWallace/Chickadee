### Fixed

- **The weekly performance benchmark reaches its database without a manual password.** `Tools/perf-bench/env.sh` gives `psql` the same default password that `start-server.sh` gives the server. The weekly task also says how to start Docker Desktop when the benchmark Postgres is down.
