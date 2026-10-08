### Fixed

- **A browser-graded Octave test that calls `setenv` no longer changes the environment of later tests.** Native grading gives each test a fresh process. In the browser every script shares one kernel, and Octave has no call that lists the environment, so the reset could not restore it. The harness now masks `setenv`, `putenv` and `unsetenv`, records each variable a script changes, and puts it back when the script ends. The session seed is not affected. (#2456)
