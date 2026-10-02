### Fixed

- A course clone that fails part-way no longer leaves the earlier assignments' zips, notebooks, solution copies and shared directories on disk. The transaction already rolled their rows back; the service now removes their files before the error leaves (#1743).
