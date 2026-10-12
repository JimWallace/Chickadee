### Changed

- **Simple pages render with Elementary.** The login, register, submission history, submission diff, student assignment history, admin import and CSV-enrolment result, OAuth consent, connected agents, LTI bind and deep-link, error, enroll, submit, editor-reset and slip-day confirmation pages are now type-checked Swift views. Each port was compared with its Leaf output and the markup is unchanged. The Leaf templates for these pages are removed.

### Fixed

- **LTI frames no longer set a session cookie.** The LTI deep-link pages rendered a CSRF token through the base layout, which created an unauthenticated session cookie inside the LMS frame. The Swift pages render no token there.
