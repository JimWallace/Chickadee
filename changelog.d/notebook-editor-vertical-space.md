### Changed

- **Notebook editor reclaims vertical space.** The student/instructor notebook
  page now hands more of the viewport to the editor itself — valuable on laptops
  and iPads. The Submit/Download header lost its 2rem top margin and slimmed its
  bottom gap, the embedded JupyterLite editor grew to match (the outer page no
  longer scrolls), and the redundant Notebook 7 header strip (jupyter/kernel
  logos, the filename + "Last Checkpoint" line, and the "Not Trusted" indicator)
  is now hidden inside the iframe. The notebook toolbar (Save/Run/kernel status)
  is unchanged.
