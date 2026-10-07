### Fixed

- **The inline event-handler check reads whole tags and JS-built HTML.** It read one line at a time and only double quotes, so a handler on a later line of a tag, in single quotes, or in an HTML string in `Public/*.js` passed. The CSP blocks each of these without an error. There were no such handlers. (#2405)
