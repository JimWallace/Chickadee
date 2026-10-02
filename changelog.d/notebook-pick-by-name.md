### Fixed

- **A zip with two notebooks routes by name.** The worker took the first `.ipynb` the filesystem listed, so a zip holding two notebooks that declare different kernels routed nondeterministically. It now takes the alphabetically first, as the student-module pick already did (#1795).
