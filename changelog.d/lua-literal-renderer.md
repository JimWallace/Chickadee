### Added

- **A browser `luaLiteral`**, pinned to `JSONValue.luaLiteral` by
  `Tests/Fixtures/lua-literal-contract.json` — the same arrangement the R
  renderer uses, where neither implementation owns the expectations and both
  read the fixture. Groundwork for in-page auto-compute on Lua.

  The contract exists mainly to pin one trap: Lua spells null `nil`, and a `nil`
  inside a table constructor **is not stored** — `{60, nil, 20}` loses its middle
  slot, `ipairs` stops at the hole, and `#t` is unspecified. So null renders
  `nil` only at top level and the `chickadee.NULL` sentinel inside any table. A
  renderer that misses that produces a table of the wrong length and grades
  against it.

### Fixed

- **`luaStringLiteral` now escapes control characters**, matching
  `encodeLuaString` in Swift. It passed them through, and a literal newline
  inside a quoted Lua string is a syntax error rather than a formatting quirk.
  The escape is decimal (`\ddd`) because `\xNN` is Lua 5.2+.
