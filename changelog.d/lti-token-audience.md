### Fixed

- **LTI grade and roster services work with Brightspace.** An LTI platform now has an optional token audience. Chickadee signs its access-token request with that audience, or with the token URL when the field is blank. Brightspace refuses the token URL and expects its "OAuth2 Audience" value, so without this field every grade push and roster read through LTI would fail.
