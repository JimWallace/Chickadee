### Changed

- **Page tests GET through one shared helper.** Fifteen suites carried a private `get` or `pageHTML` that sent the same cookie-carrying GET. They now call `getResponse(_:cookie:on:)` beside `getHTML` in `TestPageHelpers.swift`, and the suites that pass a check closure call it from their one-line wrapper. (#2362)
