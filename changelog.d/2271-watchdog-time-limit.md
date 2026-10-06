### Fixed

- **The time limit stops a script that closes its own output.** The runner took end of output on stdout and stderr as the end of the script, and stopped the time-limit timer. A script that closed both streams and kept running was never stopped. The runner now also waits for the process to exit, and the timer stays active until it does. (#2271)
