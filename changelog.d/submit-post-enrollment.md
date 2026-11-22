### Security

- **The upload form checks course enrollment on submit.** `POST /testsetups/:id/submit` checked enrollment only through the assignment row, so a draft or a REST-uploaded test setup, which has no assignment row, took a submission from any signed-in user. The route now checks enrollment first, as the form page does.
