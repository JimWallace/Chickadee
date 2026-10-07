### Fixed

- **The "Failed" count on a results page is red again, and only when a test failed.** The red rule came before the base rule in the stylesheet, so the base colour won. The count now takes the red style only when it is above zero, so a clean submission does not show a red 0. (#2399)
