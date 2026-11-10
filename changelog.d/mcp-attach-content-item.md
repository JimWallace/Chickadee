### Added

- **MCP `attach_content_item`.** An agent can now show a content item on an assignment's row, or give it a row of its own again, as the material edit form's "Show on" field does. It shares `CourseContentService.attach` with the web form, so it refuses a heading and an assignment in another course. Because an attached item reaches students only with its assignment, the result reports whether a student with no extension saw the item before the change and sees it after.
