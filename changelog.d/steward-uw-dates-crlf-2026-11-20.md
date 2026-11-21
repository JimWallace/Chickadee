### Fixed

- **The UW important dates feed parses CRLF lines on Linux.** RFC 5545 requires CRLF line endings. In Swift "\r\n" is one character, so splitting on "\n" did not split a CRLF feed on Linux, and the parser found no events. The parser now splits on CRLF, LF and CR, so a standard feed gives its events in production.
