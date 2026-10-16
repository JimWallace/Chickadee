### Added

- **Tests anchored to notebook cells, and the student guide.** Each suite item now resolves to the notebook cell that it checks, by the name that the cell defines: a pinned name, the name of a notebook check, the function of a pattern family, the names that a script uses, or the section heading. `GET /testsetups/:id/notebook-guide.json` gives the student a guide for each task, with public results only, the anchors and the personalized starter source of each anchor. The notebook editor uses it in a later change. See `docs/notebook-guide.md`.
