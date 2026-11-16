### Security

- **Workflows are linted for security.** A new CI job runs actionlint and
  zizmor on every change to `.github/`, and fails on a finding. zizmor's
  findings also go to the Security tab. Four template injections are fixed
  (an input or output pasted into a shell script now reaches it through an
  environment variable), CodeQL's write scope moves from the workflow to its
  jobs, and the Dependabot cooldown rises from 3 to 7 days (#3074).
