### Fixed

- **A Lua, Octave, Racket or Java test uploaded through the suite table is a test again.** The suite table guessed in the browser, from an extension list that had gone stale, and filed those tests as support files. The server now decides, with the same rule for both upload paths, taken from the runner's own table of what it can run. A C++ source or header uploaded through the create form is now a support file, because the runner cannot run one; C++ tests are `.sh` wrappers (#1960).
