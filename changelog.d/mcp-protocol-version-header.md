### Fixed

- **MCP transport now validates the `MCP-Protocol-Version` header.** A request
  declaring a protocol revision the server does not speak (anything other than
  2025-11-25 or 2025-06-18) is rejected with HTTP 400 per the Streamable HTTP
  transport spec, instead of being silently served. Requests without the
  header remain accepted — `initialize` is sent before negotiation, and older
  clients never send it.
