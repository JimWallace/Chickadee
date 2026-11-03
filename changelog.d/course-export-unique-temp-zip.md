### Fixed

- **Course export uses a unique temp zip path.** Two same-day exports of one course used the same temp file. `zip -r` adds to an existing archive, so the two bundles could merge, and the first stream's cleanup could delete the second's file. The temp path now has a UUID prefix; the download name does not change. `createZipArchive` now refuses an output path that already exists, so no other caller can merge archives this way (#2767).
