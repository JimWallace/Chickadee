### Changed

- **Tests for uncovered MCP tool and dispatcher paths.** New tests cover the `author_script` refusals (a generated script, a graded test sent as a support file, a grader-only file on a browser-graded assignment) and the grader-only mark and unmark, the `move_suite_item` refusals for an unknown item and its no-op move, the `preview_personalization` fallback to the acting account's own seed, the resource-method scope and missing-URI refusals, a `notifications/initialized` call that has an id, and the audit target rules. No product code changed.
