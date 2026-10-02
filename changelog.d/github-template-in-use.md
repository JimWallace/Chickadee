### Fixed

- **An assignment's GitHub template cannot be cleared or changed while course repositories exist.** Clearing it sent a student whose repository exists to owned-repository mode, which refused the organization's repository as not theirs; changing it gave later students a different start. The page now refuses with a sentence, the same gate the LTI platform delete uses (#1767).
