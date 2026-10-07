### Fixed

- **The stylesheet checks read selectors inside one-line `@media` rules.** The catalog count and the page-against-global check cut each rule at its first `{`, so a class whose rule was `@media (...) { .x { ... } }` was invisible to both. The dead `.col-hide-tablet` rule hid this way and is deleted. (#2403)
