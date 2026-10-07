### Fixed

- **The inline custom-property check reads every property in a `style` attribute.** It read only the first one, and only in an attribute that started with `--`, so a component property in second place or after `display:none;` passed. (#2404)
