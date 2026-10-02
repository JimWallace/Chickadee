### Fixed

- **A course bundle carries the starter notebook.** The export copied only the setup zip, but the starter lives beside it: the web publish and the MCP create build the zip without it, and an edit never rebuilds the zip. A web- or MCP-created assignment exported with no starter, and an uploaded one exported the original rather than the edited file. The bundle now carries the flat notebook under `testsetups/<id>.ipynb`, and import prefers it over the zip entry; an older bundle still falls back to the zip (#1736).
