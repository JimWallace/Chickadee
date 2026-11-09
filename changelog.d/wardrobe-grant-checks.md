### Changed

- **A student's result page no longer re-reads their whole grade history on each view.** The wardrobe grant read every graded submission the student had made, in every course and term, on every load of their own result page (16% of that page's CPU at one course's scale). The page now reads a one-row fingerprint first, of the student's results and of the due date and concept of each assignment they submitted to, and runs the grant only when it changed since the last complete grant. A failed write still grants again on the next load, and the account page still runs the full grant.
