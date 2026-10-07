### Fixed

- **A package install no longer counts against a browser test's time limit.** When a browser-graded script needed a package the kernel had not loaded, the install ran inside the test's time limit. A slow install timed the test out, and the next test then installed the package again in a new kernel. The clock now stops while a package installs. The script's own time, including the first attach of a package, still counts. (#2380)
