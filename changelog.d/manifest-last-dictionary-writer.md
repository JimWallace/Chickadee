### Changed

- **The last dictionary writer of a manifest is gone, and the sorted encoders share one instance.** The solution-notebook scaffold now edits the decoded manifest through `mutateManifest`; the runner's setup-cache key and the pattern-family and notebook-check spec hashes use `ManifestCodec.stableEncoder` instead of a private copy each. Bytes are unchanged. Slice 3 of #1655.
