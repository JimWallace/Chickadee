### Fixed

- **The course-code duplicate check is case-insensitive.** The unique index compares bytes while both resolvers fold case, so "cs135" and "CS135" could be two active offerings in one term that one URL key names. Every door that creates or renames a course now refuses the second (#1779).
