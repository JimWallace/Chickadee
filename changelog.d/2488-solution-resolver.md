### Fixed

- **`get_solution` finds the same solution the reveal page serves.** Four functions searched for an assignment's reference solution over three different source lists, so with only the unvalidated draft on disk the reveal page served the draft while MCP `get_solution` said there was no solution. One resolver now searches the setup zip, the linked validation run, the newest validation run and the draft in a fixed order, and each caller names the sources it accepts. A validation run still uses only a validation submission (#2488).
