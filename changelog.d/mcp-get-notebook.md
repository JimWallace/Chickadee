### Added

- **MCP authoring (read): `get_notebook` tool.** Returns an assignment's
  notebook (the starter notebook students open) as structured `.ipynb` JSON,
  plus a cell count, by assignment public ID. The first, read-only slice of
  notebook authoring (roadmap Phase 5): an agent can now inspect a notebook
  before reasoning about the suite or (later) editing the notebook. Loading
  reuses the canonical `notebookData(for:)` resolution + JupyterLite
  normalization the web notebook routes use. `content:read`, course-scoped.
