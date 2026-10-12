### Added

- **The style guards read Elementary page CSS.** `check-styles.sh`, `check-design-tokens.sh`, `check-class-resolution.sh`, `check-css-vars.sh` and `check-ui-vocabulary.sh` now read the CSS in Swift `PageStyle` blocks as well as template `<style>` blocks. A SwiftLint rule keeps flash banners in the layout, and `BaseLayoutParityTests` keeps `base.leaf` and `BaseLayout` loading the same assets while both are served.
