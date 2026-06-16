### Changed

- **Docs: corrected the Leaf decomposition roadmap note.** The previous
  "UNBLOCKED" claim was wrong for the large assignment editor pages. A
  LeafKit 1.14.2 parser bug makes two or more inline `#extend("_partial")`
  includes in one template fail at render (`LeafError.500: extend only
  supports one or two parameters []`). It is template-wide, not
  partial-specific: any second inline `#extend` on
  `assignment-new.leaf` / `assignment-edit.leaf` 500s the page. The note now
  records the evidence (bisected against the real render tests), the failed
  workarounds (bodied form, parent `#if`), and the practical rule — at most
  one inline partial `#extend` per template until leaf-kit is patched.
