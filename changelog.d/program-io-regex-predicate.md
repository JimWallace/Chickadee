### Changed

- **`get_server_info` reports the options a language refuses inside a kind.** Each language now carries `unsupportedFields`, for example Lua's `cell_contains.regex` and `program_io.ioComparison=regex`, with the reason for each. Before, an agent learned of these two refusals only when a save failed. The `program_io` regex refusal now comes from one predicate, `programIOComparisonUnsupportedReason`, which the save, the schema prose and the payload all read (#1937).
