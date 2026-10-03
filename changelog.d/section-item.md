### Changed

- **One section item type for both dashboards.** `IndexSectionItem` and `InstructorSectionItem` were one struct written twice. They are now type aliases of a generic `SectionItem<Row>`, and both templates read the assignment row as `item.row`. The pages render the same (#1712).
