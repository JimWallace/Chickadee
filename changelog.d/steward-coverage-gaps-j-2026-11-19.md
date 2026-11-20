### Changed

- **Tests for the test-setup routes.** A new suite covers the upload refusals (a manifest that is not JSON, a browser setup with no notebook, a worker setup with no suites, a zip that does not open), the flat notebook that a browser upload stores, the setup zip download (not found, a student refused, the instructor served), every refusal of the support-file download and the file it serves, and the notebook save (an empty body, a body that is not JSON, a setup that already has a notebook path). No product code changed.
