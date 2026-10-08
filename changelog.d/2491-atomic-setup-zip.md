### Fixed

- **A setup zip edit can no longer delete the zip or drop a file.** The zip rewrite helpers deleted the live zip and repacked it in place, so a failed `zip` left the setup with no zip, and an entry that failed to extract was skipped with no error. A file whose name holds `[`, `*` or `?` always failed to extract, because `unzip` read the name as a pattern, so the next edit dropped it. A rewrite now packs a new zip beside the old one and moves it into place only when it is complete, names are matched literally, and an entry that cannot be extracted fails the edit (#2491).
