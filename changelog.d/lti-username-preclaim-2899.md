### Security

- **A trusted LMS username no longer links to a locally registered account (#2899).** On a platform with "Trust this platform's username" on, a launch linked to any non-admin account with that username, including one a stranger registered through `/register` with a password they know. The stranger then held the LMS user's role. A launch now links only to an account with no local password (an SSO or LTI account); otherwise it gets its own opaque `lti-` account.
