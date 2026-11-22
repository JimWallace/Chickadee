### Fixed

- **The runner no longer retries a download that cannot succeed.** A transport error that the same request cannot get past (a bad or unsupported URL, a missing or unreadable local file, a body over the size limit) now fails the download at once. Before, every `URLError` used the full download retry budget. Network, DNS and TLS errors stay retryable. The server sends only HTTP URLs, so production was not affected.
