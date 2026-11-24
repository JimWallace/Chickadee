### Removed

- **`TestProperties.runnerSanitized()`.** Only tests called this wrapper. Tests now call `runnerManifest().testProperties`, which gives the same manifest. The runner wire form does not change (#3234).
