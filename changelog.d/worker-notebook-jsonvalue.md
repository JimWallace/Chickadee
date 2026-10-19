### Changed

- **The worker reads notebooks as `JSONValue`.** The notebook extractor,
  submission validation and normalizer parse a notebook into
  `[String: JSONValue]` in place of `[String: Any]` from `JSONSerialization`.
  `JSONValue` gains read accessors (`stringValue`, `arrayValue`,
  `objectValue`, `arrayOfObjects`, a member subscript and `object(from:)`).
  Invalid JSON is still rejected. Two edge cases differ: UTF-32 input with a
  byte-order mark is not read, and the first of two duplicate keys wins.
- **Faster `JSONValue` decoding.** The decoder tries the commonest JSON types
  first (string, object, array), which halves its cost. The result does not
  change. The worker also parses each notebook once in the extraction path,
  not twice. A notebook still takes about 2.5 times as long to parse with
  `JSONDecoder` as with `JSONSerialization`.
