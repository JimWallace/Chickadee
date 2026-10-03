### Changed

- **Shared code no longer calls up into the routes for zip and manifest work.** The test-setup zip helpers, the manifest builders and the suite-config builders moved from `Routes/Web/` to `Helpers/`, and `mutateManifest` moved beside the field edits that use it. The download response builders stayed with the routes. `scripts/check-layering.sh` now fails `format-lint` when a file under `Services/`, `Helpers/` or `Utilities/` names a symbol declared only under `Routes/`; the 27 uses that predate it are in a baseline that can only shrink (#1726).
