### Security

- **The runner refuses a submission zip that would unpack too large (#2898).** A small deflated archive can expand about 1000:1, and the runner extracts submissions outside the sandbox's disk limit. `extractZipArchive` takes optional `ZipExtractionLimits` and reads the archive's directory totals first; the runner passes `.submission` (256 MB uncompressed, 10,000 entries). An archive whose totals cannot be read is refused.
