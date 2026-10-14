### Changed

- **swift-format runs its full rule set.** The `rules` object in
  `.swift-format` replaces the tool's defaults, so the four rules it named were
  the only ones that ran. Each configuration now names every rule, and
  `scripts/check-swift-format-config.sh` fails `format-lint` when one omits a
  rule. `UseEarlyExits` and `OmitExplicitReturns` are on as well. The findings
  in `Sources/` are fixed; `Tests/.swift-format` keeps five rules off until the
  test edits are approved.
