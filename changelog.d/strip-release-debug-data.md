### Changed

- **Smaller server and runner binaries.** The image build removes the debug data from each release binary and keeps the symbol table, so a crash still names its functions. The server binary goes from 237 MB to 101 MB and the runner from 28 MB to 10 MB, which makes each deploy pull about 40 MB less. A tag build keeps the full debug data as a workflow artifact for 90 days.
