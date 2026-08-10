### Added

- **The in-page auto-compute worker can now be given its language's value
  serializer.** `AssignmentLanguage.autoComputeRuntimeSource` seeds the source a
  worker must prepend before it can report a value — the SAME serializer the
  server driver and grading runtime already use, so the two substrates cannot
  disagree about what a value looks like. Lua and Octave need one; R and Python
  do not, since `deparse` and `repr` are builtins.

  Deliberately absent: a JSON string encoder. The eval protocol frames its
  payload with a per-run nonce rather than encoding it, so no language has to
  escape anything — which matters because the tree already carries two different
  R JSON encoders (a `gsub` one in the grading runtime, and a char-by-char one
  in the personalization driver written because the first trips over
  replacement-string backslash rules). A third copy inside a worker would have
  been the worst of them.
