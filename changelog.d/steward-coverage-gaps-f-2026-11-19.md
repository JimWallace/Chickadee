### Changed

- **Tests for the refusals of the support-file URL fetcher.** A new suite covers the error text that an agent reads for each refusal, a URL that does not parse, a host that the client would read differently from the checked host, the real resolver on `localhost` and on obfuscated numeric hosts, and `fetch` and `fetchData` refusing a loopback or cloud-metadata host before they connect. No product code changed.
