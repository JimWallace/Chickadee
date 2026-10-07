### Security

- **A course bundle can no longer copy a server file into the imported course.** The import joined each submission and test setup path from the bundle manifest onto the extract directory without a check, so a crafted bundle could name a path such as `../../.worker-secret`. The import now accepts only the `<directory>/<name>` form that the export writes, and refuses any other path. (#2451)
