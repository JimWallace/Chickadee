### Fixed

- **LTI login states and deep-link requests are reaped.** `/lti/login` wrote a row per unauthenticated hit and the deep-linking launch a row per picker open, and nothing deleted either, so both tables grew without bound. An hourly sweep now removes rows that have expired or been consumed (#1646).
