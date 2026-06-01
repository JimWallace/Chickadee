### Fixed

- **Suite editor preserves dependencies when moving a test across sections.**
  Dragging a test into a different section previously cleared its `dependsOn`
  and stranded any tests depending on it in the old section, breaking the
  dependency graph. Cross-section drops now move the whole connected
  dependency cluster (transitive dependents + prerequisites) as a contiguous
  block into the target section, preserving each member's `dependsOn` and
  their topologically valid relative order. Same-section reorder is unchanged.
