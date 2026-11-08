### Changed

- **Fewer database round trips per runner result report.** The class effects read the test setup once instead of once each (five reads of the row and its manifest became one), the BrightSpace and LTI grade pushes share one read of the assignment and course inside the report's transaction, and a new diagnostics or job-metric row is inserted once instead of inserted and then updated.
