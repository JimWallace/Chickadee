### Changed

- **`mutateManifest` owns the "save only when changed" rule (#2122).** Eight single-field manifest helpers each re-decoded the manifest to decide whether to save. `mutateManifest` now compares the stable encoding with the stored bytes and writes nothing for a no-op edit, so the helpers do not. `setManifestLanguage` keeps its early return, which also guards the refusal of a change after generated scripts exist.
