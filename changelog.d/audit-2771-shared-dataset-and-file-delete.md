### Fixed

- **MCP `delete_support_file` refuses a file that a test depends on.** The web
  delete and MCP `delete_support_file` now call one service,
  `deleteFileFromSetup`. Before, the MCP path ran the steps by hand and did not
  check `dependsOn`, so an agent could delete a support file that a suite entry
  still needed. The dataset edit moved into `Services/` in the same way: the
  web `PUT /datasets` routes and MCP `set_dataset` both call
  `applyDatasetsEdit` (#2771).
