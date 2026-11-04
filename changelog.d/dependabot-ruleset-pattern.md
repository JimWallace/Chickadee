### Fixed

- **Dependabot can open pull requests again.** The `Default` branch ruleset excluded `refs/heads/dependabot/**`, which matches one path level only, so every real Dependabot branch was still refused. The exclusion is now `refs/heads/dependabot/**/*`, and the comment at the top of `.github/dependabot.yml` names that pattern and says how to check a branch name.
