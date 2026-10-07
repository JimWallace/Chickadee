### Fixed

- **Browser-graded R, Octave and Lua tests start from a clean state.** Each native test runs in a new process, but in the browser all the tests of a submission share one kernel. A test that changed the working directory, an environment variable or `options()` in R, the working directory in Octave, or a standard Lua function changed it for every later test. The grader now puts these back before each script. Octave cannot list its environment variables, so an Octave `setenv` still carries over. (#2384)
