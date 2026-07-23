### Added

- **Ungraded course content items.** Course sections can now hold reference
  material — links, notebooks, slides, documents, outlines, and headings —
  alongside graded assignments, so a course can present a "materials" page
  (Lectures / Labs / Assignments) the way a syllabus does. A content item is a
  new `APICourseContentItem` sibling of `APIAssignment`: a title, a kind, one or
  more labelled links (`{label, url}`, http(s) or site-relative only), an
  optional description and "Updated" label, and a published flag (drafts are
  hidden from students). It owns no test setup, submission, or grading pipeline —
  editing one never validates, re-grades, or closes anything. Content items and
  assignments render in separate lanes under the same section heading; a section
  with only content items still shows on both the student and instructor
  dashboards. Instructors author them from the instructor dashboard (per-section
  "+ Add material", edit, delete), and five MCP tools (`list_content_items`,
  `create_content_item`, `update_content_item`, `delete_content_item`,
  `reorder_content_items`, TA+) let an agent author the materials page. Content
  items survive course-bundle export/import (term clone), re-linked to their
  section.
