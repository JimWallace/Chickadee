### Fixed

- **A suite configuration that cannot be read is an error.** The suite config rows are now decoded once into one typed row. Before, they went through a `[String: Any]` round trip, and a config that did not parse fell back to the default suite without a word, which dropped the tiers, order and points. A row that names a file that is not found is now skipped alone, and no longer drops the rows around it. (#2305)
