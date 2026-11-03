### Security

- **The MCP support-file URL fetch connects to the address it checked (#2780).** The fetcher resolved the host and checked every address, but AsyncHTTPClient resolved the host again when it connected, so a zero-TTL record could pass the check and then send the connection to a private address. The fetcher now resolves once and pins the connection to a checked address with `dnsOverride`. IPv4 comes first when the answer has one. TLS still validates the certificate against the original hostname.
