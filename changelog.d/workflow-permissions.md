### Security

- **Workflows run with least privilege.** Every workflow now sets its
  token permissions at the top, and a job that needs more names it. Every
  checkout drops its credentials after the checkout, except the three jobs
  that push with git, so a later build or install step cannot read the
  token from `.git/config` (#3067, #3068).
