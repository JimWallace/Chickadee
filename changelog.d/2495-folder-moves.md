### Changed

- **Clearer source folders.** The pattern-family renderers moved to `Utilities/PatternFamilyRenderers/`, the notebook-check renderers to `Utilities/NotebookCheckRenderers/` and the Leaf tags to `Helpers/LeafTags/`. No code changed. `check-utilities-imports.sh` and the generated-message vocabulary test now read these folders recursively, so the moved files stay checked (#2495).
