### Changed

- **The MCP tools no longer depend on the web route layer.** The suite edit and its read-back, the suite DTOs, the runner-fleet rows and timing helpers, the runner staleness rule, the storage breakdown, the dataset-spec reader and the notebook cell count moved out of `Routes/Web` into `Services/` (and one helper into `Helpers/`). A new guard test fails when an MCP file uses a symbol that `Routes/Web` defines (#2496).
