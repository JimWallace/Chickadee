### Changed

- **`AlertSender` and `PersonalizationSubstitution` moved from `Services/` to `Utilities/` (#2148).** Both import only `Core` and `Foundation` and touch no model, request or database, so the placement rule puts them in `Utilities/`. The personalization drivers and the `PatternFamilyApplication` parts stay with their families. No behaviour change.
