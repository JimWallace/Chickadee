### Added

- **`delete_support_file` MCP tool.** Removes one non-graded support/data file from
  an assignment's test setup. `author_script(tier: "support")` could create and
  replace support files but never remove one, so retiring a helper module or a stale
  fixture meant overwriting it with a stub — leaving a dead entry in the setup zip
  that students could still download. The tool refuses graded rows (pointing at
  `delete_suite_item` or the owning family/check) and the reserved setup members
  (`test.properties.json`, `assignment.ipynb`, `solution.ipynb`), clears any
  `graderOnlyFiles` / `datasets` mark naming the file, re-syncs the shared support
  directory so student symlinks disappear, and re-runs validation — so a remaining
  test that still sources the file fails loudly instead of at submission time.
  Content catalog is now 52 tools.
