### Fixed

- **The Swift currency issue names the right kind of red.** The check now sends its exit status to the report job in its artifact. Before, the report job read an empty job output and filed "cannot run" for a run that found 12 pins behind (#3270).
