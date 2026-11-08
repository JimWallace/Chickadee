### Security

- **Students cannot read an assignment before it opens (#2897).** `GET /api/v1/testsetups/:id/assignment`, its download and the support-file route checked only enrollment, and the course vanity link redirected to the setup ID whatever the assignment's state. All four now apply the notebook page's rule: the assignment is open, or the student opened it while it was. A setup with no published assignment is refused to students. Course staff are not gated.
