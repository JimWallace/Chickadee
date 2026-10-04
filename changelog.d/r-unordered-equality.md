### Fixed

- **R `unordered_equality` no longer passes wrong answers.** It flattened both values and compared them as sorted strings, so a number matched a string, a nested list matched a flat one, and two different sets of pairs matched. It now compares each top-level element with `chickadee_equal`, as Lua does. `chickadee_equal` also matches a JSON null (`NA`) with `NA`, so a correct answer that contains a null passes in both kinds (#2016).
