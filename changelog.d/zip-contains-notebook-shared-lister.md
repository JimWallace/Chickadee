### Changed

- **`zipContainsNotebook` reads the archive through `listZipEntries`.** It ran its own `unzip -l` with a private parse of the listing; it now writes the bytes to a temporary file and asks the one zip lister, so four spawn sites share one parse (#1731).
