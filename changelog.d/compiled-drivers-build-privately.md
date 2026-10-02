### Fixed

- **The C++ and Java personalization drivers build in a private directory.** Each compiled in the shared support directory it ran in, so its own source and binary were listed as support files on the next evaluation: the C++ driver included an earlier copy of itself, the Java driver named its own source twice, and both failed with exit 3. Two students' evaluations also raced on one binary. Both now build beside the driver script in the evaluator's temp directory, and a leftover from before is ignored (#1788).
