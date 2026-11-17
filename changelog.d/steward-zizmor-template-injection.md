### Security

- **No step output pasted into a workflow script.** Eleven `run:` and `github-script` steps now read step outputs through an `env:` value, not a `${{ }}` template in the script text. This clears every zizmor `template-injection` finding in the Security tab.
