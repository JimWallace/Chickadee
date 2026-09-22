### Changed

- **Base image: Ubuntu 24.04 (noble) to 26.04 (resolute).** The build stage,
  both runtime stages and every CI job image move together, so CI keeps
  exercising the same glibc the shipped image uses. Swift stays on 6.4, which
  supports both releases.

  The move carries all seven grading toolchains at once: Python 3.12 to 3.14,
  R 4.3 to 4.5, Octave 8 to 11, Racket 8.10 to 8.18, GCC 13 to 15, the JDK 21
  to 25, and Lua 5.4.6 to 5.4.8. Chickadee teaches no Java course now, so
  `default-jdk` is left to follow the base image.

  Two package names change with the distro. `libssl3` and `libcurl4` were
  transitional names on noble and do not exist on resolute, so the image now
  asks for `libssl3t64` and `libcurl4t64`. Both resolve on noble as well.

  Browser and native grading move closer together. The vendored kernels run
  R 4.5.3 and Python 3.13.1, so native R goes from two minor versions behind
  the browser to within one patch of it, and native Octave from two majors
  behind to one ahead.

  One CI job stays on noble. SwiftLintPlugins ships a prebuilt binary linked
  against `libxml2.so.2`, and resolute ships `libxml2-16` with
  `libxml2.so.16` and no compatibility package, so the binary cannot start
  there. `format-lint` reads source and does not exercise the shipped image,
  so running it on the older base costs nothing. It moves back when SwiftLint
  publishes a binary that starts on resolute.
