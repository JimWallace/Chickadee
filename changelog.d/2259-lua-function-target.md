### Fixed

- **A Lua pattern family refuses a reserved word as its function target.** The check used Python's rule for Lua, so a target such as `end` or `then` was saved and rendered a test that no submission could pass. The target now follows Lua's own identifier rule (#2259).
