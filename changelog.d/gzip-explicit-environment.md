### Security

- **The GitHub tarball reader's `gzip` child gets an explicit environment.** It inherited the server's whole environment, the one exception to the rule that every server child is launched with `Environment.only`. A new guard asserts every `Subprocess.run` under the server passes `environment:`, with a fixture proving it fails (#1797).
