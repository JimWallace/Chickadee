### Fixed

- **The course-guidance MCP resource resolves its course segment like every other MCP course argument.** `chickadee://course/<key>/authoring-guidance` matched the course key exactly and case-sensitively, so a termed course read as "unknown resource" under its bare code or a lower-case key. The read now resolves the segment with the shared key matcher over the subject's authorable courses, and a bare code that several offerings share reads the newest term (#1782).
