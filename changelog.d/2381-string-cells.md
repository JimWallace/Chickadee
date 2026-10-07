### Fixed

- **A pattern-family string value stays a string.** When an author opened a family again, a string case value such as `"42"` or `"TRUE"` showed without quotes, and the next save stored it as a number or a boolean. The cell now shows such a string JSON-quoted, so it reads back as the same string. Ordinary text still shows without quotes. (#2381)
