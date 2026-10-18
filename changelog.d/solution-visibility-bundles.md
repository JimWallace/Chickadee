### Fixed

- **The solution-visibility doc now says what a course bundle and a clone do with the reveal policy.** It said that a `.chickadee` bundle does not carry the solution visibility or `secretRevealEnabled`. A bundle carries both (#1737). A clone copies `secretRevealEnabled` and sets the solution reveal back to hidden (#2664).
