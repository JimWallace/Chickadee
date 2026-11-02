### Fixed

- **A course code can no longer shadow a fixed route (#2666).** A course coded `data` or `submissions` lost its vanity URLs to the Data page and the submission page. The course forms, the clone forms and bundle import now refuse a code or URL key that is the first segment of a fixed route. The set is read from the live route table, so a new route reserves its segment with no list to update.
