### Changed

- **Test the grading adjustments in the personal-data export.** `DataExportRoutesTests` now checks that an export carries the student's grade overrides (assignment title, percent, note, time granted) and spent secret-reveal tokens (assignment title, time spent). An override for a setup that no assignment uses exports no title. No product code changed.
