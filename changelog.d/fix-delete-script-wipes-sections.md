### Fixed

- **Deleting a test no longer wipes all sections.** The manifest-rebuild
  helpers used by the add-script and delete-script endpoints
  (`updateManifestAddingScript` / `updateManifestRemovingScript`) only
  forwarded the test list and pattern families to the manifest builder, so
  every other field — the `sections` list, each surviving entry's
  `sectionID` membership, notebook checks, `generatedByCheck`/`hint`, and the
  assignment-scope global variables/expressions — was silently dropped on
  every single-script add or delete. Deleting one test therefore deleted all
  of an assignment's sections. The helpers now carry the full manifest
  through the rebuild.
