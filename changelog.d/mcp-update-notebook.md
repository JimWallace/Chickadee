### Added

- **MCP authoring (write): `update_notebook` tool.** Lets an authorized agent
  replace an assignment's starter notebook (the notebook students open) with new
  `.ipynb` JSON, by assignment public ID. The agent supplies the full notebook
  (a JSON object with a `cells` array); the server applies the same JupyterLite
  kernel normalization + flat-file write the web editor's Save uses and re-runs
  validation, so the two paths can't drift. Narrow blast radius: only the flat
  notebook is written (the setup zip stays archival), and existing student
  working copies are left untouched so an edit never clobbers in-progress work —
  students pick up the new notebook when their copy is next reset. `content:write`,
  course-scoped.
