### Fixed

- **Notebook checks read the header of a CRLF CSV.** The data-frame and Series equality checks split the expected CSV on line breaks with a test that missed Windows (CRLF) endings. A CRLF CSV was read as one line: a CSV with no header was accepted, and a one-column Series with a comma in a later row was refused. Both checks now split on every line break.
