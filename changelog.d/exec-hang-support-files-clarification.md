### Fixed

- **Editor `exec_hang` fix (v0.4.526) also restores support-file access.** That
  release noted surfacing the Drive's support files into the kernel as "a
  separate follow-up"; it proved unnecessary — once the chdir fix creates the
  working folder, JupyterLite populates it with the Drive's support files
  (verified end-to-end: a no-service-worker kernel reads a seeded support file).
  No code change; the full root-cause record now lives in
  `docs/exec-hang-investigation.md`.
