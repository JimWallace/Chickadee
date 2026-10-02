### Changed

- **The course clone tests pin every reset against a set value.** The admin clone source had no start date or deadline override, so two of its reset assertions could not fail, and the instructor New term test asserted only an assignment count. Both sources now carry a due date, a start date, an active override and an after-due reveal, and both tests assert each reset (#1785).
