### Security

- **CodeQL also scans the workflows and the Python scripts.** The `actions`
  analysis looks for untrusted input that reaches a shell, privileged
  triggers and over-wide token permissions. The `python` analysis covers
  `scripts/` and `Tools/` (#3073).
