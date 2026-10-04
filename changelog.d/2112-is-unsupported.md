### Removed

- **`SupportedBrowserMatrix.isUnsupported(userAgent:)` (#2112).** No production code called it. Both pages read `assess(_:).tier`. The four test assertions that called it now read the tier, beside the assertions that already did.
