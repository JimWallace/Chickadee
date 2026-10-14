### Changed

- **SwiftLint checks modern Swift idioms.** Twenty-two opt-in rules are on,
  among them `shorthand_optional_binding`, `prefer_key_path`, `redundant_self`,
  `legacy_multiple`, `implicitly_unwrapped_optional` and
  `unhandled_throwing_task`. The findings in `Sources/` are fixed.
  `Tests/.swiftlint.yml` keeps the rules with test findings off until the test
  edits are approved. The renamed `operator_whitespace` rule has its new name,
  and `unused_import` moves to `analyzer_rules`; as an opt-in rule it never ran.
