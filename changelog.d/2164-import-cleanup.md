### Fixed

- **A failed course bundle import removes the files it wrote (#2164).** The rows rolled back with the transaction, but the setup zips, notebooks, shared directories, content attachments and submission files stayed on disk. The import now records each path before it writes and removes them all when the transaction fails, as the course clone does.
