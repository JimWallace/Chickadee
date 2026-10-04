### Fixed

- **An auto-compute error shows in the Expected cell even when the cell held a computed value.** The error set only the placeholder and the hover title, and a value computed earlier hid the placeholder, so on a touch screen the error did not show at all. Every auto-compute failure now clears the computed value first (#1998).
