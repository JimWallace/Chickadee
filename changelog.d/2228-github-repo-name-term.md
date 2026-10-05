### Fixed

- **A course repository's name carries the course term.** A clone keeps its assignment slugs and may bind the same GitHub organization, so a student who repeated a course could not make a repository in the new offering: the name `{slug}-{login}` was taken by the first one. A course with a term now names it `{slug}-{term}-{login}`, for example `lab1-W27-alice`; a course with no term keeps the old name (#2228).
