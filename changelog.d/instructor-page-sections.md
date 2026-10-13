### Changed

- **The instructor tabbed pages keep their content in `.page-section` blocks.** Overview, Activity, Students, Slip days, LEARN and LMS grades no longer put a titlebar, a toolbar or a table straight under the tab bar. A new test, `InstructorTabbedSectionsTests`, keeps every instructor tabbed page that way. The pages gain the section's bottom margin.
- **The assignment editors use `.page-titlebar`.** `.editor-titlebar` repeated it. The editors now use `.page-titlebar` with the new `.page-titlebar--top` modifier, which holds the actions at the top of a tall title column.
