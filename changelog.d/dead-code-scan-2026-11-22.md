### Removed

- **Dead code from the 2026-11-22 dead-code scan.** Two lab-group model initializers that nothing called, and two parameters that their functions never read: `app:` on `materializeValidationGrading` and `courseUUID:` on the BrightSpace `syncSummary`. Also 14 unused test helpers, properties and parameters. Behaviour does not change.
