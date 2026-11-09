### Fixed

- **Staff editor: no "Directory not found" loop.** In the production image the editor drive's folder is a link to the data volume, and a staff listing of the drive root answered 404, so the file browser showed "Directory not found" on every poll. The contents routes now resolve the link first.
