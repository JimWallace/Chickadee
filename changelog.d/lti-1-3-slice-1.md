### Added

- **LTI 1.3 foundations (slice 1).** Chickadee can now hold LTI 1.3 platform registrations (`lti_platforms`), publishes its RS256 tool key set at `GET /lti/jwks`, and has the launch claim rules and the LTI-role to course-role mapping that the launch route will use. Nothing changes for a deployment with no enabled platform: the key set is empty and no tool key is written. Design and slice plan: `docs/lti-1-3.md`.
