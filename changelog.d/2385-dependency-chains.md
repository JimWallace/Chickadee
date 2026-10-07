### Fixed

- **The suite table shows every test in a dependency chain.** A test that depended on a test which itself depended on another had no row in the suite table, so an author could not edit or delete it, although it still graded. Every link of a chain now has a row. (#2385)
