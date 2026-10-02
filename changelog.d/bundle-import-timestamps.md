### Fixed

- **Bundle import keeps each submission's `submittedAt` and each result's `receivedAt`.** The export wrote both; the import let the create stamp set them to import time, so student history showed the import date and two carried solutions tied on their timestamp. Each row is stamped from the bundle after it is created (#1739).
