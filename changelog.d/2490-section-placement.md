### Fixed

- **A new content item sorts after the assignments in its section.** The content-item paths took the next order from content items only, so a new item in a section of assignments got order 1 and sorted near the top. Every create and move path now uses one order over both tables, and MCP `create_assignment` and the clones no longer leave the order empty (#2490).
- **A move into a section asks the manifest rules once.** The web move and MCP `set_assignment_course_section` each restated three of the rules that decide whether a section's browser default can be adopted. Both now ask `ManifestCoherence`, so a new rule reaches them too (#2490).
