### Fixed

- **Editing an existing test in the unified Test Editor modal now opens the right editor.** The shell resolved which renderer to show from the (hidden) type dropdown's leftover value instead of the edit payload, so editing a notebook check or a custom script silently fell through to a blank pattern-family form. Imported Marmoset suites — which are entirely raw scripts — were therefore uneditable. The modal now takes the mechanism and kind from the item being edited.
