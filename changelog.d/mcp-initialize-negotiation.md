### Changed

- **MCP `initialize` now negotiates the protocol version and logs the
  client's identity.** A supported requested revision (2025-06-18 or
  2025-11-25) is echoed back per the lifecycle spec; an unsupported one gets
  the latest the server speaks. The connecting client's `clientInfo`
  name/version and the negotiated revision are logged for operational
  visibility into which agents talk to the server.
