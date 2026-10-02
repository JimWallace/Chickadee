### Fixed

- A GitHub commit status post is abandoned after 20 seconds, and every GitHub API call carries a 30-second timeout, so a GitHub connection that stops answering no longer holds the runner's result report open (#1773).
