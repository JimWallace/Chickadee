### Security

- **The image gate also fails on HIGH.** A CRITICAL or HIGH vulnerability
  with a fix now stops the server image and the arm64 runner image before
  they are pushed. An accepted finding goes in `.trivyignore.yaml` with a
  reason and an expiry date (#3077).
