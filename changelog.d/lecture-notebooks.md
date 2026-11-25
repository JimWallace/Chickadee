### Added

- **Lecture notebooks.** A course can host an ungraded lecture notebook that students open and run in the notebook editor, each in a copy of their own. It has no Submit button, no grade, no LMS push and no validation. Staff add one from a section's "+ Add" menu (title, language, optional `.ipynb`) and edit it in the editor with "Save lecture notebook". MCP agents author one with `create_content_item` / `update_content_item` (`lectureNotebook`) and read it with `get_lecture_notebook`. See `docs/lecture-notebooks.md`.
