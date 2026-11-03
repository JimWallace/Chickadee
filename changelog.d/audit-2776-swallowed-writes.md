### Fixed

- **Failed writes no longer leave wrong state behind in silence (#2776).** A server with no runner secret now fails at startup when the wordlist is missing or the generated secret cannot be saved; a saved secret still starts as before. A failed dataset write is no longer cached as current, so the next visit retries it. BrightSpace sync bookkeeping, sync log rows and the cached-id clear now log a failed save. A match row or a wardrobe unlock ignores only the unique-constraint conflict: a match row now throws on any other failure, and a wardrobe unlock logs it.
