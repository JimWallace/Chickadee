### Changed

- **Docker base image: Ubuntu 22.04 (jammy) → 24.04 (noble).** Both Dockerfile
  stages move together — build (`swift:6.3-jammy` → `swift:6.3-noble`) and
  runtime/prebuilt (`ubuntu:22.04` → `ubuntu:24.04`) — so the
  statically-linked-stdlib binaries still match the runtime glibc. All CI jobs
  are unified onto `swift:6.3-noble` (the historical format-lint-on-noble /
  tests-on-jammy split is gone, since noble's glibc 2.39 already satisfied the
  SwiftLintBinary GLIBC 2.38 requirement), and the now-unused jammy image is
  dropped from the mirror workflow. **Grading-environment note:** the runtime
  stage's apt packages move to noble's versions — Python 3.10 → 3.12, plus newer
  numpy / pandas / scipy / matplotlib and R — so student submissions graded on
  the worker now run against that newer environment. Validate representative
  assignments before deploying.
