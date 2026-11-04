### Fixed

- **Support files in a subfolder reach the student's notebook.** A setup-zip
  file such as `data/patients.csv` was never linked into a student's
  JupyterLite working copy, because its parent folder was not made first, and
  the failure was not logged. The link pass now makes the parent folders and
  logs each link it cannot make. The `files.missing` authoring check already
  counted such a file as delivered, so it now agrees with what students get.
