### Removed

- **Dead code from the 2026-11-22 dead-code scan.** Two lab-group model initializers that nothing called, and three parameters that their functions never read: `app:` on `materializeValidationGrading`, `courseUUID:` on the BrightSpace `syncSummary`, and `total:` on `DatasetMaterializer.apportion`. Also 14 unused test helpers, properties and parameters. Behaviour does not change.
