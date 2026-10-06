### Changed

- **One typed JupyterLite contents model.** The contents routes build one `Encodable` `JupyterContentsModel` for files, notebooks and directories, in place of two `[String: Any]` dictionaries. A JSON file is checked to parse, then its own bytes go into the response, so a large notebook is no longer decoded and encoded again on each request. The keys and values the JupyterLite client reads do not change. (#2308)
