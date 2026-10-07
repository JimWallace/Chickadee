### Fixed

- **The colour-token check catches CSS named colours.** It matched only hex, `rgb()` and `hsl()` values, so `color: white` on the primary button passed. That rule now uses a palette token. (#2406)
