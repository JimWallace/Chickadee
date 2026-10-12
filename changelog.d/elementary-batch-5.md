### Changed

- **The editors and the workbench render with Elementary.** The assignment editor, the new-assignment page, the notebook page and the assignment workbench are now type-checked Swift views, and no route renders a Leaf template any more. Each port was compared with its Leaf output, including the spaces between inline elements. A few templates (`assignment-edit.leaf`, `workbench.leaf` and the partials they extend) stay unserved as the exemplars that `PageArchetypeTests` reads.

### Security

- **Server-made JSON in a page cannot end its script element.** The editors embed JSON in `<script type="application/json">` elements. The new `JSONIsland` view writes every `<` in that JSON as `<`, so text an author wrote, such as a test name, cannot close or change the element. The page scripts read the same values.
