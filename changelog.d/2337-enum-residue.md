### Fixed

- **create_content_item refuses an unknown kind.** It stored an unknown `kind` as a link without a word, while `update_content_item` refused the same value. Both now refuse it and name the legal kinds; an absent kind is still a link. The last hand-typed MCP enum lists (achievement scope and comparator, section item type, content-item kinds in the served instructions) are now derived from their types, and the notebook-check and pattern-family kind errors name the legal values. (#2337)
