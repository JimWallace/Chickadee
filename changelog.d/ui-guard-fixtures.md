### Fixed

- **`check-leaf-semantics.sh` reads a whole tag parameter list.** Its regex stopped at the first `)`, so `#if(count(rows) > 0 && other.isEmpty)` passed, and the `count()` fix is what produces that shape. It now counts parenthesis depth. It also rejects Leaf tag syntax inside an HTML comment (an interpolation, or a structural tag name such as the extend), which Leaf runs as if it were in the markup (#1971).

### Added

- **Fixtures for five `check-styles.sh` rules that had none:** the page-style and JS-style ratchets, the cross-page duplicate selector rule, the per-datum inline property rule and the list-filter rule. The two ratchet fixtures add one line more than the baseline, so they hold whatever today's count is (#1971).
